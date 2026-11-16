#!/usr/bin/env bats

# The hooks that run on the laptop: build, release-check, post-deploy, bump.

setup() {
  load helpers
  common_setup
  a_tree
  export TURPIN_CREATED=2026-11-16T10:00:00Z TURPIN_SHORT_SHA=0123456
}

# ----------------------------------------------------------------- build

@test "build refuses with no build time, then bakes both images once it has it" {
  unset TURPIN_CREATED
  run "$TREE/turpin/hooks/build"
  assert_failure 1
  assert_output --partial "TURPIN_CREATED is not set"
  export TURPIN_CREATED=2026-11-16T10:00:00Z
  run "$TREE/turpin/hooks/build"
  assert_success
}

@test "build bakes server and web in one call, labelled, to OCI layouts, and names them" {
  run "$TREE/turpin/hooks/build"
  assert_success
  assert_line "server .turpin/oci/server"
  assert_line "web .turpin/oci/web"
  [[ "$(grep -c . "$DOCKER_LOG")" == 1 ]]
  run cat "$DOCKER_LOG"
  assert_line --partial "buildx bake --builder turpin -f docker-compose.yml"
  assert_line --partial "--set server.labels.org.opencontainers.image.revision=$TURPIN_SHA"
  assert_line --partial "--set web.labels.org.opencontainers.image.version=0.10.2"
  assert_line --partial "--set server.labels.org.opencontainers.image.created=2026-11-16T10:00:00Z"
  assert_line --partial "--set server.output=type=oci,dest=.turpin/oci/server,tar=false"
  assert_line --partial "--set web.args.TILE_LITE_ELITE_BUILD_ID=0123456"
  assert_line --regexp " server web\$"
}

@test "build labels each image with the highest migration number, 9 here, not 0009" {
  run "$TREE/turpin/hooks/build"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line --partial "--set server.labels.org.tileliteelite.schema=9 "
  assert_line --partial "--set web.labels.org.tileliteelite.schema=9 "
}

@test "build takes the build id from the commit when Turpin gives no short SHA" {
  unset TURPIN_SHORT_SHA
  command git -C "$TREE" init -q
  command git -C "$TREE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  export TURPIN_SHA="$(command git -C "$TREE" rev-parse HEAD)"
  run "$TREE/turpin/hooks/build"
  assert_success
  run cat "$DOCKER_LOG"
  assert_line --partial "server.args.TILE_LITE_ELITE_BUILD_ID=${TURPIN_SHA:0:7}"
}

@test "build refuses where it can name no schema" {
  rm "$TREE"/crates/server-game/migrations/*.sql
  run "$TREE/turpin/hooks/build"
  assert_failure 1
  assert_output --partial "holds no migration"
}

@test "build fails where docker buildx fails, naming no layout" {
  export STUB_DOCKER_RC=1
  run "$TREE/turpin/hooks/build"
  assert_failure
  refute_output --partial ".turpin/oci"
}

@test "build only builds the images Turpin asks for" {
  export TURPIN_BUILD_IMAGES=web
  run "$TREE/turpin/hooks/build"
  assert_success
  assert_output "web .turpin/oci/web"
}

@test "build under TURPIN_LOCAL loads the images, tagged as Turpin says, and names them alone" {
  export TURPIN_LOCAL=1
  run "$TREE/turpin/hooks/build"
  assert_failure 1
  assert_output --partial "TURPIN_BUILD_TAG_SERVER is not set"
  export TURPIN_BUILD_TAG_SERVER=turpin-local/tle-server:abc TURPIN_BUILD_TAG_WEB=turpin-local/tle-web:abc
  run "$TREE/turpin/hooks/build"
  assert_success
  assert_line "server"
  assert_line "web"
  refute_output --partial ".turpin"
  run cat "$DOCKER_LOG"
  assert_line --partial "--load"
  assert_line --partial "--set server.tags=turpin-local/tle-server:abc"
  refute_line --partial "output=type=oci"
}

# --------------------------------------------------------- release-check

@test "release-check refuses a version check-release-version.sh refuses, and passes one it passes" {
  cd "$TREE"
  export STUB_RELEASE_CHECK_RC=1
  run "$EXPORT_HOOKS/release-check"
  assert_failure 1
  assert_output --partial "refused 0.10.2"
  export STUB_RELEASE_CHECK_RC=0
  run "$EXPORT_HOOKS/release-check"
  assert_success
  run cat "$RELEASE_CHECK_LOG"
  assert_output "0.10.2 strict=1"
}

@test "release-check refuses where the script that judges is not there" {
  cd "$TREE"
  rm "$TREE/scripts/deliver/check-release-version.sh"
  run "$EXPORT_HOOKS/release-check"
  assert_failure 1
  assert_output --partial "cannot judge"
}

@test "release-check refuses where it cannot tell what the version is" {
  cd "$TREE"
  unset TURPIN_VERSION
  run "$EXPORT_HOOKS/release-check"
  assert_failure 1
}

@test "release-check finds the repository from the working directory, with the hooks exported apart from it, and asks for strict" {
  cd "$TREE"
  [[ ! -e "$EXPORT_HOOKS/../../scripts" ]]
  run "$EXPORT_HOOKS/release-check"
  assert_success
  run cat "$RELEASE_CHECK_LOG"
  assert_output "0.10.2 strict=1"
}

@test "release-check refuses where the working directory is no repository" {
  cd "$BATS_TEST_TMPDIR"
  run "$EXPORT_HOOKS/release-check"
  assert_failure 1
  assert_output --partial "not in a git repository"
}

# ----------------------------------------------------------- post-deploy

@test "post-deploy says not yet where /health reports another version, and passes where it reports this one" {
  export TURPIN_URL=https://tileliteelite.test STUB_HEALTH='{"app_version":"0.10.1+2bbb957"}'
  run "$HOOKS/post-deploy"
  assert_failure 75
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}'
  run "$HOOKS/post-deploy"
  assert_success
}

@test "post-deploy refuses where the environment has no address" {
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_failure 1
  assert_output --partial "TURPIN_URL is not set"
}

@test "post-deploy with no address reads TARGET_URL from the repository's rehearsal-target.sh" {
  export TURPIN_ENV=rehearsal
  printf 'export TARGET_URL=https://rehearsal.test\n' > "$TREE/scripts/deliver/rehearsal-target.sh"
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}'
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_success
  assert_output --partial "https://rehearsal.test/health reports"
  run cat "$CURL_LOG"
  assert_line --partial "https://rehearsal.test/health"
}

@test "post-deploy with no address and a script that gives none refuses" {
  export TURPIN_ENV=rehearsal
  printf 'export OTHER=1\n' > "$TREE/scripts/deliver/rehearsal-target.sh"
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_failure 1
  assert_output --partial "TURPIN_URL is not set"
}

@test "post-deploy: a TURPIN_URL that is set wins over rehearsal-target.sh" {
  export TURPIN_ENV=rehearsal TURPIN_URL=https://given.test
  printf 'export TARGET_URL=https://rehearsal.test\n' > "$TREE/scripts/deliver/rehearsal-target.sh"
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}'
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_success
  run cat "$CURL_LOG"
  assert_line --partial "https://given.test/health"
  refute_line --partial "rehearsal.test"
}

@test "post-deploy on rehearsal takes REHEARSAL_URL before rehearsal-target.sh" {
  export TURPIN_ENV=rehearsal REHEARSAL_URL=https://env.test
  printf 'export TARGET_URL=https://rehearsal.test\n' > "$TREE/scripts/deliver/rehearsal-target.sh"
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}'
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_success
  run cat "$CURL_LOG"
  assert_line --partial "https://env.test/health"
}

@test "post-deploy off rehearsal never reads rehearsal-target.sh" {
  export TURPIN_ENV=production
  printf 'export TARGET_URL=https://rehearsal.test\n' > "$TREE/scripts/deliver/rehearsal-target.sh"
  cd "$TREE"
  run "$HOOKS/post-deploy"
  assert_failure 1
  assert_output --partial "TURPIN_URL is not set"
}

@test "post-deploy after production lists the open Release Check issues, and does not refuse for them" {
  export TURPIN_URL=https://tileliteelite.test TURPIN_ENV=production
  export STUB_HEALTH='{"app_version":"0.10.2+0123456"}' STUB_ISSUES="  #310  Compare the image digest"
  run "$HOOKS/post-deploy"
  assert_success
  assert_output --partial "#310  Compare the image digest"
  run cat "$GH_LOG"
  assert_line --partial "issue list --label Release Check --state open"
}

@test "post-deploy after rehearsal does not list them" {
  export TURPIN_URL=https://x.test STUB_HEALTH='{"app_version":"0.10.2+0123456"}' STUB_ISSUES="  #310  x"
  run "$HOOKS/post-deploy"
  assert_success
  refute_output --partial "#310"
  [[ ! -s "$GH_LOG" ]]
}

# ------------------------------------------------------------------ bump

@test "bump refuses where cargo fails, then refreshes the lockfile offline once it works" {
  export STUB_CARGO_RC=1
  run "$TREE/turpin/hooks/bump"
  assert_failure 1
  assert_output --partial "does not follow 0.10.2"
  export STUB_CARGO_RC=0
  run "$TREE/turpin/hooks/bump"
  assert_success
  run cat "$CARGO_LOG"
  assert_line "update --workspace --offline"
}
