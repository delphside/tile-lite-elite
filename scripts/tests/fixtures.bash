# Shared by the bats files that run the tooling: point the loader at the fake
# profiles instead of Tile Lite Elite's (#485 stage 2). `load fixtures`, then
# `use_fake_profiles` in setup.

export FAKES="$(cd "$BATS_TEST_DIRNAME/../programme/board/tests/fixtures" && pwd)"

use_fake_profiles() {
  export PROGRAMME_PROFILE="$FAKES/programme.toml"
  export PROGRAMME_CONFIG="$FAKES/programme-config.toml"
  export PROGRAMME_DIR="$FAKES/live"
}
