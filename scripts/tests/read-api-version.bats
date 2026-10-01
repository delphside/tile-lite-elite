#!/usr/bin/env bats

# read-api-version.sh, run as its callers run it: its own `set -euo pipefail`
# holds, because bats runs it as a separate process. A harness that relaxed it
# once let a silent-abort bug through to a production deploy (docs/3.3,
# "Rolling back").

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  READ="$BATS_TEST_DIRNAME/../application/deliver/read-api-version.sh"
}

reads() { run "$READ" <<< "$1"; }

@test "single line" {
  reads 'pub const API_VERSION: ApiVersion = ApiVersion { major: 2, minor: 9 };'
  assert_success
  assert_output "2.9"
}

# What rustfmt produces once the numbers no longer fit on one line: the shape
# that broke both callers.
@test "wrapped over four lines" {
  reads 'pub const API_VERSION: ApiVersion = ApiVersion {
    major: 2,
    minor: 10,
};'
  assert_success
  assert_output "2.10"
}

@test "two-digit major and minor" {
  reads 'pub const API_VERSION: ApiVersion = ApiVersion {
    major: 11,
    minor: 204,
};'
  assert_success
  assert_output "11.204"
}

@test "surrounded by other code" {
  reads '// leading comment mentioning API_VERSION in prose
pub const OTHER: u8 = 1;
pub const API_VERSION: ApiVersion = ApiVersion { major: 3, minor: 0 };
pub struct Trailing;'
  assert_success
  assert_output "3.0"
}

# Must fail rather than print nothing: a caller that cannot read the version
# has to stop, not carry on believing it is unchanged. This is the case that
# made check-commit-stamp.sh skip its own check in silence.
@test "an absent version exits non-zero" {
  reads 'no version here at all'
  assert_failure
}
