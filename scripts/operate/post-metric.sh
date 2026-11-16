#!/usr/bin/env bash
# Post one datapoint to OCI Monitoring, namespace `tile_lite_elite` (#608, #224).
#
# **The host reports; the application never holds an OCI credential.** The
# instance principal is a host credential, scoped by policy to `metrics:post`
# in this namespace, and the whole backup arrangement rests on the container not
# being able to read what it wrote (#224 R3).
#
# **The OCI Python SDK, not the CLI and not a hand-signed request.** Signing by
# hand fails quietly, and a job that posts on its success path without checking
# the response reports a healthy backup forever while posting nothing. So this
# exits 0 only when the SDK's response says the datapoint was accepted with no
# failed metrics. The host needs the `oci` Python package.
#
# **General on purpose.** Any metric name, any dimensions: later callers add
# rates with their own dimensions without changing this. The policy's namespace
# condition bounds it, not this script.
#
# Usage: post-metric.sh <metric> <value> [key=value ...]
#   post-metric.sh JobSucceeded 1 job=backup
# `resourceId`, the instance's OCID from the metadata service, is added to every
# datapoint; do not pass it.
#
# Exit: 0 accepted; 1 the response did not report the datapoint accepted;
#       2 could not post (no metadata, no SDK, a refused or failed call);
#       64 usage error.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: post-metric.sh <metric> <value> [key=value ...]

Posts one datapoint to OCI Monitoring namespace tile_lite_elite, with the
given dimensions plus resourceId (this instance's OCID, read from the
instance metadata service). Authenticates with the instance principal
through the OCI Python SDK (the `oci` package must be installed).

Exits:
  0   the response reported the datapoint accepted, no failed metrics
  1   the response did not
      -> "error: datapoint not accepted: ..."
  2   could not post: no instance metadata, no SDK, or the call failed
      -> "error: ..."
  64  usage error
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -lt 2 ]]; then usage >&2; exit 64; fi

IMDS="${IMDS_URL:-http://169.254.169.254/opc/v2}"
imds() {   # <path>
  curl --fail --silent --show-error --max-time 5 \
    -H 'Authorization: Bearer Oracle' "$IMDS/$1"
}
RESOURCE_ID="$(imds instance/id)" \
  || { echo "error: cannot read the instance OCID from the metadata service" >&2; exit 2; }
COMPARTMENT_ID="$(imds instance/compartmentId)" \
  || { echo "error: cannot read the compartment from the metadata service" >&2; exit 2; }

# -I: isolated mode, so nothing in the environment or the working directory can
# put a module of its own in front of the SDK.
python3 -I -c '
import sys
from datetime import datetime, timezone

metric, value, resource_id, compartment_id, *pairs = sys.argv[1:]
NAMESPACE = "tile_lite_elite"


def refuse(code, why):
    print("error: " + why, file=sys.stderr)
    sys.exit(code)


try:
    value = float(value)
except ValueError:
    refuse(64, "value is not a number: " + value)

dimensions = {}
for pair in pairs:
    key, sep, val = pair.partition("=")
    if not sep or not key or not val:
        refuse(64, "dimension is not key=value: " + pair)
    if key == "resourceId" or key in dimensions:
        refuse(64, "dimension given twice or reserved: " + key)
    dimensions[key] = val
dimensions["resourceId"] = resource_id

try:
    import oci
    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner()
    client = oci.monitoring.MonitoringClient(
        config={},
        signer=signer,
        service_endpoint="https://telemetry-ingestion.%s.oraclecloud.com" % signer.region,
    )
    details = oci.monitoring.models.PostMetricDataDetails(
        metric_data=[oci.monitoring.models.MetricDataDetails(
            namespace=NAMESPACE,
            compartment_id=compartment_id,
            name=metric,
            dimensions=dimensions,
            datapoints=[oci.monitoring.models.Datapoint(
                timestamp=datetime.now(timezone.utc), value=value)],
        )]
    )
    response = client.post_metric_data(details)
except Exception as error:
    refuse(2, "could not post %s: %s: %s" % (metric, type(error).__name__, error))

data = response.data
failed = getattr(data, "failed_metrics_count", None)
if response.status != 200 or failed != 0 or getattr(data, "failed_metrics", None):
    refuse(1, "datapoint not accepted: status %s, failed metrics %s, %s" % (
        response.status, failed, getattr(data, "failed_metrics", None)))
print("posted %s=%s %s" % (metric, value, dimensions))
' "$1" "$2" "$RESOURCE_ID" "$COMPARTMENT_ID" "${@:3}"
