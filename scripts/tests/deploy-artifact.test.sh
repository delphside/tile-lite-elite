#!/usr/bin/env bash
set -euo pipefail

# Tests deploy.sh's build artefact: one build per commit, reused by every
# environment that deploys it (#214 R1).
#
# The behaviour these cover could previously only be observed by deploying
# twice and timing it, which is why it was never observed at all. `docker` is
# stubbed, so a "build" is a file appearing rather than three minutes of cargo.
#
# Run under the same `set -euo pipefail` deploy.sh runs with: a harness without
# pipefail once hid a silent abort that reached production.

HERE="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

# A workspace with a stubbed `docker` on PATH, and deploy.sh's functions
# sourced. DEPLOY_SH_FUNCTIONS_ONLY stops the script before the deploy itself.
setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/artifacts" "$WORK/worktree"
  BUILDS="$WORK/builds.log"
  : > "$BUILDS"

  cat > "$WORK/bin/docker" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "compose" ]]; then
  echo "build" >> "$BUILDS"
  exit 0
fi
if [[ "\$1" == "save" ]]; then
  echo "image-bytes-for-this-build"
  exit 0
fi
exit 0
STUB
  chmod +x "$WORK/bin/docker"
  touch "$WORK/worktree/docker-compose.yml"

  PATH="$WORK/bin:$PATH"
  ARTIFACT_DIR="$WORK/artifacts"
  # shellcheck disable=SC1090
  DEPLOY_SH_FUNCTIONS_ONLY=1 REPO_DIR="$WORK" ARTIFACT_DIR="$WORK/artifacts" \
    source "$HERE/scripts/deploy.sh"
}

teardown() { rm -rf "$WORK"; }

check() {
  local what="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$what"
  else
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$what" "$want" "$got"
    failures=$((failures + 1))
  fi
}

SHA=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee

echo "deploy-artifact"

# 1 — the first build produces an artefact named for the commit, and a digest
setup
build_artifact "$SHA" "$WORK/worktree" > /dev/null
check "first build writes artifacts/<sha>.tar.gz" "yes" \
      "$([[ -f "$WORK/artifacts/$SHA.tar.gz" ]] && echo yes || echo no)"
check "first build records a digest beside it" "yes" \
      "$([[ -s "$WORK/artifacts/$SHA.tar.gz.sha256" ]] && echo yes || echo no)"
check "the recorded digest is the file's" \
      "$(sha256sum "$WORK/artifacts/$SHA.tar.gz" | cut -d' ' -f1)" \
      "$(cat "$WORK/artifacts/$SHA.tar.gz.sha256")"

# 2 — the case R1 exists for: a second deploy of one commit does not rebuild
build_artifact "$SHA" "$WORK/worktree" > /dev/null
check "deploying the same commit again does not rebuild" "1" "$(wc -l < "$BUILDS")"
teardown

# 3 — a different commit does build
setup
build_artifact "$SHA" "$WORK/worktree" > /dev/null
build_artifact "ffffffff11111111222222223333333344444444" "$WORK/worktree" > /dev/null
check "a different commit builds its own artefact" "2" "$(wc -l < "$BUILDS")"
teardown

# 4 — verify_artifact returns the digest, and refuses a corrupted one
setup
build_artifact "$SHA" "$WORK/worktree" > /dev/null
check "verify returns the digest" \
      "$(cat "$WORK/artifacts/$SHA.tar.gz.sha256")" \
      "$(verify_artifact "$WORK/artifacts/$SHA.tar.gz")"

echo "truncated" > "$WORK/artifacts/$SHA.tar.gz"
set +e
verify_artifact "$WORK/artifacts/$SHA.tar.gz" > /dev/null 2>&1
corrupt_status=$?
set -e
check "verify refuses an artefact that does not match its digest" "1" "$corrupt_status"

rm -f "$WORK/artifacts/$SHA.tar.gz.sha256"
set +e
verify_artifact "$WORK/artifacts/$SHA.tar.gz" > /dev/null 2>&1
nodigest_status=$?
set -e
check "verify refuses an artefact with no recorded digest" "1" "$nodigest_status"
teardown

# 5 — an interrupted build leaves nothing that looks complete
setup
cat > "$WORK/bin/docker" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "compose" ]] && exit 0
[[ "\$1" == "save" ]] && { echo partial; exit 1; }
exit 0
STUB
chmod +x "$WORK/bin/docker"
set +e
build_artifact "$SHA" "$WORK/worktree" > /dev/null 2>&1
set -e
check "a failed save leaves no artefact behind" "no" \
      "$([[ -f "$WORK/artifacts/$SHA.tar.gz" ]] && echo yes || echo no)"
teardown

# 6 — pruning keeps the most recent and removes the rest
setup
for n in 1 2 3 4 5 6 7; do
  printf 'x' > "$WORK/artifacts/sha$n.tar.gz"
  printf 'd' > "$WORK/artifacts/sha$n.tar.gz.sha256"
  sleep 0.01
done
prune_artifacts 3
check "prune keeps the requested number" "3" \
      "$(ls -1 "$WORK/artifacts"/*.tar.gz 2>/dev/null | wc -l)"
check "prune keeps the newest" "yes" \
      "$([[ -f "$WORK/artifacts/sha7.tar.gz" ]] && echo yes || echo no)"
check "prune takes the digest file with it" "no" \
      "$([[ -f "$WORK/artifacts/sha1.tar.gz.sha256" ]] && echo yes || echo no)"
teardown

# --- the build manifest (#288) ----------------------------------------------
#
# A real git fixture, because every line of the manifest is derived from the
# repository — commits, paths, trailers, tags. A stubbed `git` would be written
# against the same assumptions as the code, and two of the three defects found
# while writing this were assumptions: `git show` inheriting the loop's stdin
# and truncating the issue list to three of ten, and the previous tag being
# taken as "the newest that exists" rather than "the newest that is an
# ancestor", which reported `commits (0)` for any commit already carrying one.

setup_repo() {
  setup
  REPO_DIR="$WORK/repo"; mkdir -p "$REPO_DIR"
  git -C "$REPO_DIR" init -q .
  git -C "$REPO_DIR" config user.email t@t; git -C "$REPO_DIR" config user.name t
  mkdir -p "$REPO_DIR/docs" "$REPO_DIR/crates/ui/src"

  echo one > "$REPO_DIR/docs/a.md"
  git -C "$REPO_DIR" add -A; git -C "$REPO_DIR" commit -q -m "base"
  git -C "$REPO_DIR" tag -a prod-0.1.0 -m released

  echo two > "$REPO_DIR/docs/b.md"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "docs only" -m "Refs #900"

  echo three > "$REPO_DIR/crates/ui/src/x.rs"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "the image changes" -m "Refs #901"

  echo four > "$REPO_DIR/docs/c.md"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "cites #902 in prose and claims nothing" -m "Refs #900"

  HEAD_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
}

echo "the build manifest"
setup_repo
MAN="$(write_manifest "$HEAD_SHA" "feedface")"

check "a manifest is written beside the artefact" "yes" \
      "$([[ -f "$WORK/artifacts/$HEAD_SHA.manifest" ]] && echo yes || echo no)"
check "it names the digest it describes" "1" "$(grep -c '^digest    sha256:feedface$' "$MAN")"
check "it names the previous production tag"  "1" "$(grep -c '^since     prod-0.1.0' "$MAN")"
check "a commit touching crates/ is marked as reaching the image" "1" \
      "$(grep -c '^  \* .*the image changes' "$MAN")"
check "a commit touching only docs/ is not" "1" \
      "$(grep -cE '^    [0-9a-f]+  docs only' "$MAN")"
check "an issue claimed by a trailer appears" "1" "$(grep -c '^  #901' "$MAN")"
# `^  #902` rather than `#902`: the string also appears in the commit subject
# listed above, which is correct — the manifest shows what each commit said.
# The looser assertion failed for the right reason and the wrong grep.
check "an issue only cited in prose does not" "0" "$(grep -c '^  #902' "$MAN")"
check "an issue claimed twice counts both commits" "1" "$(grep -c '^  #900    2 commit' "$MAN")"
check "the image marker follows the issue" "1" \
      "$(grep -c '^  #901    1 commit(s), reaches the image' "$MAN")"
check "an issue whose commits miss the image is unmarked" "1" \
      "$(grep -cE '^  #900    2 commit\(s\)$' "$MAN")"

# The truncation that looked like a working filter: three of ten, printed
# correctly. Every claimed issue must be reached.
for n in 903 904 905 906 907 908 909 910; do
  echo "x$n" > "$REPO_DIR/docs/$n.md"; git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -q -m "more" -m "Refs #$n"
done
MAN2="$(write_manifest "$(git -C "$REPO_DIR" rev-parse HEAD)" "feedface")"
check "every claimed issue is listed, not the first few" "10" "$(grep -c '^  #9' "$MAN2")"

# A commit already carrying a tag: the range is measured from the tag before it.
git -C "$REPO_DIR" tag -a prod-0.2.0 -m released
MAN3="$(write_manifest "$(git -C "$REPO_DIR" rev-parse HEAD)" "feedface")"
check "a commit that is itself tagged still lists its range" "1" \
      "$(grep -c '^since     prod-0.1.0' "$MAN3")"
check "and the range is not empty" "0" "$(grep -c '^commits (0)' "$MAN3")"

touch "$WORK/artifacts/$HEAD_SHA.tar.gz"
prune_artifacts 0
check "prune removes the manifest too" "no" \
      "$([[ -f "$WORK/artifacts/$HEAD_SHA.manifest" ]] && echo yes || echo no)"
teardown


# --- the plan/build disagreement report (#288 R3) ----------------------------
#
# `gh` is stubbed per issue. The quiet case is here because it is the one a
# broken check passes by accident — and three of the four defects found while
# writing this made noise rather than silence, so a check that only ever spoke
# would have looked right.

stub_gh() {   # $1 = "<num>:<type>:<milestone> ..." — milestone may be empty
              # $2 = optional space-separated issue numbers that are parents
  cat > "$WORK/bin/gh" <<STUB
#!/usr/bin/env bash
# **Dispatch on the endpoint**, per this file's own rule. \`is_parent\` asks
# \`sub_issues\` and reads a count; the issue view asks for the type and the
# milestone and reads a TSV row. Answering the first with the second made every
# issue look like a parent, so the report named nothing and three checks passed
# by reporting nothing — found 2026-09-10 when the parent exemption landed.
case "\$*" in
  *sub_issues*)
    sub="\${*}"; sub="\${sub##*issues/}"; sub="\${sub%%/sub_issues*}"
    for p in ${2:-}; do
      [[ "\$p" == "\$sub" ]] && { printf '1\n'; exit 0; }
    done
    printf '0\n'; exit 0 ;;
esac
num=""
for a in "\$@"; do case "\$a" in [0-9]*) num="\$a"; break ;; esac; done
for spec in $1; do
  n="\${spec%%:*}"; rest="\${spec#*:}"
  if [[ "\$n" == "\$num" ]]; then
    printf '%s\t%s\n' "\${rest%%:*}" "\${rest##*:}"; exit 0
  fi
done
printf '%s\t%s\n' "Project" ""
STUB
  chmod +x "$WORK/bin/gh"
}

echo "the plan/build disagreement report"

setup_repo
stub_gh "900:Project:0.1.0 901:Project:"
out="$(report_plan_disagreement "$HEAD_SHA" 0.1.0 2>&1 || true)"
check "an image-touching issue with no milestone is named" "1" "$(grep -c '#*901' <<< "$out")"
check "an issue that has one is not" "0" "$(grep -c ' 900' <<< "$out")"

stub_gh "900:Project:0.1.0 901:Project:0.1.0"
out="$(report_plan_disagreement "$HEAD_SHA" 0.1.0 2>&1 || true)"
check "the quiet case says nothing at all" "" "$out"

# A milestone that is not this release still counts: an issue may ride a
# release under an earlier letter, which is what 0.7.1a and 0.7.1b are for.
stub_gh "901:Project:0.0.9a"
out="$(report_plan_disagreement "$HEAD_SHA" 0.1.0 2>&1 || true)"
check "an earlier milestone counts as filed" "" "$out"

# A Requirement cannot carry a milestone at all — docs/3.6 1.1.
# A parent, for the same reason as the Requirement below: `CLAUDE.md` says it
# needs no milestone and one set is ignored, so asking for one asks for
# something the process forbids. #370 — the 0.8.0 rehearsal and deploy both
# named #301, #344 and #297, all parents.
stub_gh "901:Project:" "901"
out="$(report_plan_disagreement "$HEAD_SHA" 0.1.0 2>&1 || true)"
check "a parent is never asked for a milestone" "0" "$(grep -c '901' <<< "$out")"

stub_gh "901:Requirement:"
out="$(report_plan_disagreement "$HEAD_SHA" 0.1.0 2>&1 || true)"
check "a requirement is never asked for a milestone" "" "$out"
teardown


if (( failures )); then
  echo "  $failures check(s) failed"
  exit 1
fi
echo "  all checks passed"
