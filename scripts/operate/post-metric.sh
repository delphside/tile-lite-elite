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
# failed metrics.
#
# **The SDK is third-party code, and 1.10's standard-library-only rule is set
# aside for it** by D49 (#337): request signing is the one thing not to write
# ourselves. It is the SDK in the `~/oci/` virtualenv, which carries it for the
# OCI CLI that fetches the registry token (programme 3.1.2), so nothing more is
# installed; `OCI_PYTHON` names another interpreter.
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
# Exit (docs/1.10): 0 accepted;
#       1 the response did not report the datapoint accepted;
#       2 the SDK is not importable;
#       64 usage error;
#       75 could not post, and a retry may work: the metadata service did not
#          answer, or the SDK's call raised (network, throttling, a refusal).
set -euo pipefail

usage() {
  cat <<'EOF'
usage: post-metric.sh <metric> <value> [key=value ...]
       OCI_PYTHON=... post-metric.sh ...

Posts one datapoint to OCI Monitoring namespace tile_lite_elite, with the
given dimensions plus resourceId (this instance's OCID, read from the
instance metadata service). Authenticates with the instance principal
through the OCI Python SDK, run by ~/oci/bin/python3 or $OCI_PYTHON.

Exits:
  0   the response reported the datapoint accepted, no failed metrics
  1   the response did not
      -> "error: datapoint not accepted: ..."
  2   the SDK cannot be imported
      -> "error: the OCI SDK is not importable: ..."
  64  usage error
  75  could not post, and a retry may work: no answer from the metadata
      service, or the SDK's call raised
      -> "error: could not post <metric>: <type> status <n> code <c>"
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
if [[ $# -lt 2 ]]; then usage >&2; exit 64; fi

# --- validate before anything is asked of the network -------------------------
METRIC="$1"; VALUE="$2"; shift 2
[[ "$VALUE" =~ ^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] \
  || { echo "error: value is not a number: $VALUE" >&2; exit 64; }
declare -A SEEN=()
for pair in "$@"; do
  key="${pair%%=*}"; val="${pair#*=}"
  if [[ "$pair" != *=* || -z "$key" || -z "$val" ]]; then
    echo "error: dimension is not key=value: $pair" >&2; exit 64
  fi
  if [[ "$key" == resourceId || -n "${SEEN[$key]:-}" ]]; then
    echo "error: dimension given twice or reserved: $key" >&2; exit 64
  fi
  SEEN[$key]=1
done

IMDS="${IMDS_URL:-http://169.254.169.254/opc/v2}"
imds() {   # <path>
  curl --fail --silent --show-error --max-time 5 \
    -H 'Authorization: Bearer Oracle' "$IMDS/$1"
}
RESOURCE_ID="$(imds instance/id)" \
  || { echo "error: cannot read the instance OCID from the metadata service" >&2; exit 75; }
COMPARTMENT_ID="$(imds instance/compartmentId)" \
  || { echo "error: cannot read the compartment from the metadata service" >&2; exit 75; }

# -I: isolated mode, so nothing in the environment or the working directory can
# put a module of its own in front of the SDK.
"${OCI_PYTHON:-$HOME/oci/bin/python3}" -I -c '
import sys
from datetime import datetime, timezone

metric, value, resource_id, compartment_id, *pairs = sys.argv[1:]
NAMESPACE = "tile_lite_elite"


def refuse(code, why):
    print("error: " + why, file=sys.stderr)
    sys.exit(code)


dimensions = dict(pair.split("=", 1) for pair in pairs)
shown = dict(dimensions)
dimensions["resourceId"] = resource_id

try:
    import oci
except ImportError as error:
    refuse(2, "the OCI SDK is not importable: %s" % error)

try:
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
                timestamp=datetime.now(timezone.utc), value=float(value))],
        )]
    )
    response = client.post_metric_data(details)
except Exception as error:
    # The type, and the HTTP status and error code where the SDK gives them: the
    # message can carry identifiers, and a log is read by more than the owner.
    why = type(error).__name__
    for field in ("status", "code"):
        if getattr(error, field, None) is not None:
            why += " %s %s" % (field, getattr(error, field))
    refuse(75, "could not post %s: %s" % (metric, why))

data = response.data
failed = getattr(data, "failed_metrics_count", None)
if response.status != 200 or failed != 0 or getattr(data, "failed_metrics", None):
    refuse(1, "datapoint not accepted: status %s, failed metrics %s" % (response.status, failed))
print("posted %s=%s %s" % (metric, value, shown))
' "$METRIC" "$VALUE" "$RESOURCE_ID" "$COMPARTMENT_ID" "$@"
