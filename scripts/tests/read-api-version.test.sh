#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/read-api-version.sh, under the same `set -euo pipefail` the
# callers run with — a harness that relaxes it once let a silent-abort bug
# through to a production deploy (docs/3.3, "Rolling back").

HERE="$(cd "$(dirname "$0")/.." && pwd)"
READ="$HERE/read-api-version.sh"
failures=0

check() {
  local name="$1" input="$2" want="$3" got
  got="$(printf '%s' "$input" | "$READ" 2>/dev/null || echo "<failed>")"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted '$want', got '$got'"
    failures=$((failures + 1))
  fi
}

check "single line" \
  'pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 9 };' \
  "2.9"

# What rustfmt produces once the numbers no longer fit on one line — the shape
# that broke both callers.
check "wrapped over four lines" \
  'pub const API_VERSION: ApiVersion = ApiVersion {
    major: 2,
    minor: 10,
};' \
  "2.10"

check "two-digit major and minor" \
  'pub const API_VERSION: ApiVersion = ApiVersion {
    major: 11,
    minor: 204,
};' \
  "11.204"

check "surrounded by other code" \
  '// leading comment mentioning API_VERSION in prose
pub const OTHER: u8 = 1;
pub const API_VERSION: ApiVersion = ApiVersion { major: 3, minor: 0 };
pub struct Trailing;' \
  "3.0"

# Must fail rather than print nothing: a caller that cannot read the version
# has to stop, not carry on believing it is unchanged. This is the case that
# made `check-commit-stamp.sh` skip its own check in silence.
if printf 'no version here at all\n' | "$READ" > /dev/null 2>&1; then
  echo "FAIL absent version: exited 0, so a caller would read it as 'no change'"
  failures=$((failures + 1))
else
  echo "ok   absent version exits non-zero"
fi

if (( failures > 0 )); then
  echo
  echo "$failures failed"
  exit 1
fi
echo
echo "all passed"
