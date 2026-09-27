#!/usr/bin/env bats

# deploy.sh's build artefact: one build per commit, reused by every environment
# that deploys it (#214 R1), with its manifest (#288) and the plan/build
# disagreement report (#288 R3).
#
# The behaviour could previously only be observed by deploying twice and timing
# it, which is why it was never observed at all. docker is stubbed, so a build
# is a file appearing rather than three minutes of cargo; gh is stubbed where the
# report asks it; git runs against a scratch repository.

SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  W="$BATS_TEST_TMPDIR"
  mkdir -p "$W/bin" "$W/artifacts" "$W/worktree"
  BUILDS="$W/builds.log"; : > "$BUILDS"
  docker_stub 0
  touch "$W/worktree/docker-compose.yml"
  export PATH="$W/bin:$PATH" REPO_DIR="$W" ARTIFACT_DIR="$W/artifacts"
  # shellcheck source=/dev/null
  DEPLOY_SH_FUNCTIONS_ONLY=1 source "$BATS_TEST_DIRNAME/../deploy.sh"
}

docker_stub() {   # <save-exit>: `compose` records a build, `save` prints bytes
  cat > "$W/bin/docker" <<STUB
#!/usr/bin/env bash
[[ "\$1" == compose ]] && { echo build >> "$BUILDS"; exit 0; }
[[ "\$1" == save ]] && { echo image-bytes-for-this-build; exit $1; }
exit 0
STUB
  chmod +x "$W/bin/docker"
}

build() { build_artifact "$1" "$W/worktree" > /dev/null 2>&1; }

@test "the first build writes artifacts/<sha>.tar.gz and a digest that is the file's" {
  build "$SHA"
  assert [ -f "$W/artifacts/$SHA.tar.gz" ]
  assert [ -s "$W/artifacts/$SHA.tar.gz.sha256" ]
  assert_equal "$(cat "$W/artifacts/$SHA.tar.gz.sha256")" "$(sha256sum "$W/artifacts/$SHA.tar.gz" | cut -d' ' -f1)"
}

# The case R1 exists for.
@test "deploying the same commit again does not rebuild" {
  build "$SHA"; build "$SHA"
  assert_equal "$(wc -l < "$BUILDS")" 1
}

@test "a different commit builds its own artefact" {
  build "$SHA"; build ffffffff11111111222222223333333344444444
  assert_equal "$(wc -l < "$BUILDS")" 2
}

@test "verify returns the digest, and refuses a corrupted artefact or one with no digest" {
  build "$SHA"
  assert_equal "$(verify_artifact "$W/artifacts/$SHA.tar.gz")" "$(cat "$W/artifacts/$SHA.tar.gz.sha256")"
  echo truncated > "$W/artifacts/$SHA.tar.gz"
  run verify_artifact "$W/artifacts/$SHA.tar.gz"
  assert_equal "$status" 1
  rm -f "$W/artifacts/$SHA.tar.gz.sha256"
  run verify_artifact "$W/artifacts/$SHA.tar.gz"
  assert_equal "$status" 1
}

@test "an interrupted build leaves nothing that looks complete" {
  docker_stub 1
  build "$SHA" || true
  assert [ ! -f "$W/artifacts/$SHA.tar.gz" ]
}

@test "pruning keeps the newest few, and takes each digest with its artefact" {
  local n
  for n in 1 2 3 4 5 6 7; do
    printf x > "$W/artifacts/sha$n.tar.gz"; printf d > "$W/artifacts/sha$n.tar.gz.sha256"; sleep 0.01
  done
  prune_artifacts 3
  assert_equal "$(ls -1 "$W/artifacts"/*.tar.gz | wc -l)" 3
  assert [ -f "$W/artifacts/sha7.tar.gz" ]
  assert [ ! -f "$W/artifacts/sha1.tar.gz.sha256" ]
}

# --- the build manifest (#288) -------------------------------------------------
# A real git fixture, because every line of the manifest is derived from the
# repository. Two of the three defects found while writing this were
# assumptions a stubbed git would have shared: `git show` inheriting the loop's
# stdin and truncating the issue list to three of ten, and the previous tag
# taken as the newest that exists rather than the newest that is an ancestor.

repo() {
  export REPO_DIR="$W/repo"; mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q .
  git -C "$REPO_DIR" config user.email t@t; git -C "$REPO_DIR" config user.name t
  mkdir -p "$REPO_DIR/docs" "$REPO_DIR/crates/ui/src"
  echo one > "$REPO_DIR/docs/a.md"; git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -q -m base
  git -C "$REPO_DIR" tag -a prod-0.1.0 -m released
  echo two > "$REPO_DIR/docs/b.md"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "docs only" -m "Refs #900"
  echo three > "$REPO_DIR/crates/ui/src/x.rs"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "the image changes" -m "Refs #901"
  echo four > "$REPO_DIR/docs/c.md"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "cites #902 in prose and claims nothing" -m "Refs #900"
  HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
}

lines() { grep -cE "$1" "$2" || true; }

@test "manifest: written beside the artefact, naming the digest and the previous tag" {
  repo
  man="$(write_manifest "$HEAD_SHA" feedface)"
  assert [ -f "$W/artifacts/$HEAD_SHA.manifest" ]
  assert_equal "$(lines '^digest    sha256:feedface$' "$man")" 1
  assert_equal "$(lines '^since     prod-0.1.0' "$man")" 1
}

@test "manifest: a crates/ commit is marked as reaching the image, a docs/ one is not" {
  repo
  man="$(write_manifest "$HEAD_SHA" feedface)"
  assert_equal "$(lines '^  \* .*the image changes' "$man")" 1
  assert_equal "$(lines '^    [0-9a-f]+  docs only' "$man")" 1
}

# `^  #902` rather than `#902`: the string also appears in the commit subject,
# which is correct, since the manifest shows what each commit said.
@test "manifest: an issue claimed by a trailer appears, one cited in prose does not" {
  repo
  man="$(write_manifest "$HEAD_SHA" feedface)"
  assert_equal "$(lines '^  #901' "$man")" 1
  assert_equal "$(lines '^  #902' "$man")" 0
}

@test "manifest: an issue claimed twice counts both, and only image commits are marked" {
  repo
  man="$(write_manifest "$HEAD_SHA" feedface)"
  assert_equal "$(lines '^  #900    2 commit' "$man")" 1
  assert_equal "$(lines '^  #901    1 commit\(s\), reaches the image' "$man")" 1
  assert_equal "$(lines '^  #900    2 commit\(s\)$' "$man")" 1
}

# The truncation that looked like a working filter: three of ten, printed correctly.
@test "manifest: every claimed issue is listed, not the first few" {
  repo
  local n
  for n in 903 904 905 906 907 908 909 910; do
    echo "x$n" > "$REPO_DIR/docs/$n.md"; git -C "$REPO_DIR" add -A
    git -C "$REPO_DIR" commit -q -m more -m "Refs #$n"
  done
  man="$(write_manifest "$(git -C "$REPO_DIR" rev-parse HEAD)" feedface)"
  assert_equal "$(lines '^  #9' "$man")" 10
}

# The range is measured from the tag before it.
@test "manifest: a commit that is itself tagged still lists its range, not an empty one" {
  repo
  git -C "$REPO_DIR" tag -a prod-0.2.0 -m released
  man="$(write_manifest "$HEAD_SHA" feedface)"
  assert_equal "$(lines '^since     prod-0.1.0' "$man")" 1
  assert_equal "$(lines '^commits \(0\)' "$man")" 0
}

@test "prune removes the manifest too" {
  repo
  write_manifest "$HEAD_SHA" feedface > /dev/null
  touch "$W/artifacts/$HEAD_SHA.tar.gz"
  prune_artifacts 0
  assert [ ! -f "$W/artifacts/$HEAD_SHA.manifest" ]
}

# --- the plan/build disagreement report (#288 R3) ------------------------------
# The quiet case is here because it is the one a broken check passes by
# accident; three of the four defects found while writing this made noise
# rather than silence.

gh_stub() {   # "<num>:<type>:<milestone> ..." [parent numbers]
  # Dispatches on the endpoint: is_parent asks sub_issues and reads a count, the
  # issue view reads a TSV row. Answering the first with the second made every
  # issue look like a parent, and three checks passed by reporting nothing.
  cat > "$W/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *sub_issues*)
    sub="\${*}"; sub="\${sub##*issues/}"; sub="\${sub%%/sub_issues*}"
    for p in ${2:-}; do [[ "\$p" == "\$sub" ]] && { printf '1\n'; exit 0; }; done
    printf '0\n'; exit 0 ;;
esac
num=""
for a in "\$@"; do case "\$a" in [0-9]*) num="\$a"; break ;; esac; done
for spec in $1; do
  n="\${spec%%:*}"; rest="\${spec#*:}"
  [[ "\$n" == "\$num" ]] && { printf '%s\t%s\n' "\${rest%%:*}" "\${rest##*:}"; exit 0; }
done
printf '%s\t%s\n' Project ""
STUB
  chmod +x "$W/bin/gh"
}

report() { run report_plan_disagreement "$HEAD_SHA" 0.1.0; }

@test "report: an image-touching issue with no milestone is named, one with a milestone is not" {
  repo; gh_stub "900:Project:0.1.0 901:Project:"
  report
  assert_output --partial 901
  refute_output --partial ' 900'
}

@test "report: the quiet case says nothing at all" {
  repo; gh_stub "900:Project:0.1.0 901:Project:0.1.0"
  report
  assert_output ""
}

# An issue may ride a release under an earlier letter, which is what 0.7.1a
# and 0.7.1b are for.
@test "report: an earlier milestone counts as filed" {
  repo; gh_stub "901:Project:0.0.9a"
  report
  assert_output ""
}

# CLAUDE.md: a parent needs no milestone and one set is ignored, so asking for
# one asks for something the process forbids. #370: the 0.8.0 rehearsal and
# deploy both named #301, #344 and #297, all parents.
@test "report: a parent is never asked for a milestone" {
  repo; gh_stub "901:Project:" 901
  report
  refute_output --partial 901
}

# docs/3.6 §1.1: a requirement cannot carry a milestone at all.
@test "report: a requirement is never asked for a milestone" {
  repo; gh_stub "901:Requirement:"
  report
  assert_output ""
}
