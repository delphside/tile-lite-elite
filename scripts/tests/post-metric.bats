#!/usr/bin/env bats

# post-metric.sh, against a stubbed metadata service (curl) and a fake `oci`
# package. The real embedded Python program runs, so what is checked is what the
# script decides from the SDK's response, which is the whole point of it: a
# helper that reports success without checking the response builds the alarm's
# blind spot into the alarm (#224 R3).
#
# `python3 -I` ignores PYTHONPATH, so the stub interpreter (named by OCI_PYTHON,
# as on the host) drops the -I, records that it was given, and puts the fake
# package in front. Nothing here can reach
# OCI: the package is ours and curl is a stub.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  SCRIPT="$BATS_TEST_DIRNAME/../operate/post-metric.sh"
  D="$BATS_TEST_TMPDIR"
  REAL_PY="$(command -v python3)"
  mkdir -p "$D/bin" "$D/pylib/oci"

  # The metadata service: the instance OCID and the compartment.
  cat > "$D/bin/curl" <<'STUB'
#!/usr/bin/env bash
[[ -z "${IMDS_EXIT:-}" ]] || exit "$IMDS_EXIT"
# The metadata service refuses a request without its header.
[[ "$*" == *"Authorization: Bearer Oracle"* ]] || exit 22
case "${@: -1}" in
  */instance/id)            printf 'ocid1.instance.test' ;;
  */instance/compartmentId) printf 'ocid1.compartment.test' ;;
  *) exit 22 ;;
esac
STUB

  cat > "$D/bin/oci-python" <<STUB
#!/usr/bin/env bash
echo "\$1" > "$D/python-flag"
[[ "\$1" == -I ]] && shift
PYTHONPATH="$D/pylib" exec "$REAL_PY" "\$@"
STUB
  chmod +x "$D/bin/curl" "$D/bin/oci-python"
  export OCI_PYTHON="$D/bin/oci-python"

  # A fake SDK. FAKE_OCI_MODE picks the response; the datapoint posted is
  # written to $FAKE_OCI_OUT as JSON.
  cat > "$D/pylib/oci/__init__.py" <<'PY'
import json
import os
from types import SimpleNamespace as NS


class ServiceError(Exception):
    def __init__(self, message, status=404, code="NotAuthorizedOrNotFound"):
        super().__init__(message)
        self.status = status
        self.code = code


class RequestException(Exception):
    pass


class ConnectTimeout(Exception):
    pass


class Signer:
    region = "test-region-1"


class Details(NS):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)


class Client:
    def __init__(self, config, signer, service_endpoint):
        self.endpoint = service_endpoint

    def post_metric_data(self, details):
        mode = os.environ.get("FAKE_OCI_MODE", "accepted")
        if mode == "raises":
            raise ServiceError("ocid1.instance.secret is not authorised")
        if mode == "raises-429":
            raise ServiceError("slow down", 429, "TooManyRequests")
        if mode == "raises-503":
            raise ServiceError("down", 503, "InternalServerError")
        if mode == "raises-connect":
            raise RequestException("ocid1.x unreachable")
        if mode == "raises-connect-timeout":
            raise ConnectTimeout("ocid1.x")
        if mode == "raises-timeout":
            raise TimeoutError("ocid1.x")
        if mode == "raises-other":
            raise ValueError("ocid1.x surprise")
        metric = details.metric_data[0]
        with open(os.environ["FAKE_OCI_OUT"], "w") as out:
            json.dump({
                "endpoint": self.endpoint,
                "namespace": metric.namespace,
                "compartment": metric.compartment_id,
                "name": metric.name,
                "dimensions": metric.dimensions,
                "value": metric.datapoints[0].value,
                "has_timestamp": metric.datapoints[0].timestamp is not None,
            }, out)
        if mode == "failed":
            return NS(status=200, data=NS(failed_metrics_count=1,
                                          failed_metrics=[NS(message="bad")]))
        if mode == "no-count":
            return NS(status=200, data=NS())
        if mode == "http-500":
            return NS(status=500, data=NS(failed_metrics_count=0, failed_metrics=[]))
        return NS(status=200, data=NS(failed_metrics_count=0, failed_metrics=[]))


exceptions = NS(ServiceError=ServiceError, RequestException=RequestException,
                ConnectTimeout=ConnectTimeout)
auth = NS(signers=NS(InstancePrincipalsSecurityTokenSigner=Signer))
monitoring = NS(
    MonitoringClient=Client,
    models=NS(PostMetricDataDetails=Details, MetricDataDetails=Details, Datapoint=Details),
)
PY
  export FAKE_OCI_OUT="$D/posted.json"
}

post() { run env PATH="$D/bin:$PATH" bash "$SCRIPT" "$@"; }

field() {   # <python expression over d>
  "$REAL_PY" -c "import json; d = json.load(open('$FAKE_OCI_OUT')); print($1)"
}

@test "an accepted datapoint exits 0 and carries the namespace, name, value and dimensions" {
  post JobSucceeded 1 job=backup
  assert_success
  assert_equal "$(field 'd["namespace"]')" tile_lite_elite
  assert_equal "$(field 'd["name"]')" JobSucceeded
  assert_equal "$(field 'd["value"]')" 1.0
  assert_equal "$(field 'sorted(d["dimensions"].items())')" "[('job', 'backup'), ('resourceId', 'ocid1.instance.test')]"
  assert_equal "$(field 'd["compartment"]')" ocid1.compartment.test
  assert_equal "$(field 'd["has_timestamp"]')" True
}

@test "the ingestion endpoint is the signer's region" {
  post JobSucceeded 1 job=backup
  assert_equal "$(field 'd["endpoint"]')" "https://telemetry-ingestion.test-region-1.oraclecloud.com"
}

@test "any metric and any dimensions are posted, for later callers" {
  post HttpErrors 2.5 error_type=timeout status_class=5xx bucket=le_1
  assert_success
  assert_equal "$(field 'd["name"]')" HttpErrors
  assert_equal "$(field 'd["value"]')" 2.5
  assert_equal "$(field 'len(d["dimensions"])')" 4
}

@test "no dimensions still posts, with resourceId alone" {
  post RestoreDrillAgeDays 3
  assert_success
  assert_equal "$(field 'list(d["dimensions"])')" "['resourceId']"
}

@test "without OCI_PYTHON it runs the ~/oci virtualenv's interpreter" {
  mkdir -p "$D/home/oci/bin"
  cp "$D/bin/oci-python" "$D/home/oci/bin/python3"
  run env -u OCI_PYTHON HOME="$D/home" PATH="$D/bin:$PATH" bash "$SCRIPT" JobSucceeded 1 job=backup
  assert_success
}

@test "the program runs isolated, with -I, under the interpreter OCI_PYTHON names" {
  post JobSucceeded 1 job=backup
  assert_equal "$(cat "$D/python-flag")" "-I"
}

# The case the whole helper exists for.
@test "failed metrics in the response are a failure, naming why" {
  FAKE_OCI_MODE=failed post JobSucceeded 1 job=backup
  assert_equal "$status" 1
  assert_output --partial "datapoint not accepted"
}

@test "a response that does not say how many failed is not an acceptance" {
  FAKE_OCI_MODE=no-count post JobSucceeded 1 job=backup
  assert_equal "$status" 1
  assert_output --partial "datapoint not accepted"
}

@test "a non-200 status is not an acceptance" {
  FAKE_OCI_MODE=http-500 post JobSucceeded 1 job=backup
  assert_equal "$status" 1
}

@test "a refusal a retry will not change exits 2, naming the type, status and code and no more" {
  FAKE_OCI_MODE=raises post JobSucceeded 1 job=backup
  assert_equal "$status" 2
  assert_output --partial "could not post JobSucceeded: ServiceError status 404 code NotAuthorizedOrNotFound"
  refute_output --partial "ocid1"
}

@test "throttling and server errors exit 75" {
  FAKE_OCI_MODE=raises-429 post JobSucceeded 1 job=backup
  assert_equal "$status" 75
  FAKE_OCI_MODE=raises-503 post JobSucceeded 1 job=backup
  assert_equal "$status" 75
  assert_output --partial "status 503"
}

@test "connection and timeout errors exit 75" {
  local mode
  for mode in raises-connect raises-connect-timeout raises-timeout; do
    FAKE_OCI_MODE=$mode post JobSucceeded 1 job=backup
    assert_equal "$status" 75
    refute_output --partial "ocid1"
  done
}

@test "anything else the SDK raises is unexpected, exit 70" {
  FAKE_OCI_MODE=raises-other post JobSucceeded 1 job=backup
  assert_equal "$status" 70
  assert_output --partial "ValueError"
  refute_output --partial "ocid1"
}

@test "an interpreter that is not executable is exit 2, with the SDK-missing message" {
  OCI_PYTHON="$D/bin/no-such-python" post JobSucceeded 1 job=backup
  assert_equal "$status" 2
  assert_output --partial "the OCI SDK is not importable"
}

@test "no oci package is exit 2, not a silent success" {
  rm -rf "$D/pylib/oci"
  post JobSucceeded 1 job=backup
  assert_equal "$status" 2
  assert_output --partial "not importable"
}

@test "the output names the dimensions given and never the instance or compartment" {
  post JobSucceeded 1 job=backup
  assert_output --partial "'job': 'backup'"
  refute_output --partial "ocid1"
}

@test "arguments are validated before the metadata service is asked" {
  IMDS_EXIT=7 post JobSucceeded notanumber
  assert_equal "$status" 64
  IMDS_EXIT=7 post JobSucceeded 1 job
  assert_equal "$status" 64
}

@test "no metadata service is a retryable failure, and nothing is posted" {
  IMDS_EXIT=7 post JobSucceeded 1 job=backup
  assert_equal "$status" 75
  assert_output --partial "metadata service"
  assert [ ! -e "$FAKE_OCI_OUT" ]
}

@test "usage errors exit 64 and post nothing" {
  post JobSucceeded
  assert_equal "$status" 64
  post JobSucceeded notanumber
  assert_equal "$status" 64
  post JobSucceeded 1 job
  assert_equal "$status" 64
  post JobSucceeded 1 resourceId=other
  assert_equal "$status" 64
  post JobSucceeded 1 job=a job=b
  assert_equal "$status" 64
  assert [ ! -e "$FAKE_OCI_OUT" ]
}

@test "--help exits 0 and names the exits" {
  post --help
  assert_success
  assert_output --partial "64  usage error"
}
