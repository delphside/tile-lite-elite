#!/usr/bin/env bash
set -euo pipefail
# pre-commit-hook.test.sh — the image rule refuses what ships and passes what
# does not.
#
# Run under the same `set -euo pipefail` the hook itself runs under: a harness
# missing pipefail once hid a silent abort that reached a production deploy.
#
# The rule is an allowlist of non-shipping paths, so the cases that matter most
# are the ones nobody listed: an unrecognised new file at the repo root must be
# refused, not waved through.

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.githooks/pre-commit"
PASS=0; FAIL=0

# One throwaway repo per case: the hook reads the branch, the index and HEAD.
run_case() {
  local desc="$1" expect="$2"; shift 2
  local tmp got=0; tmp="$(mktemp -d)"
  # `|| got=$?` and not a bare call: under `set -e` a failing subshell aborts
  # the script before the next line runs, so every refusal case would vanish.
  (
    cd "$tmp"
    git init -q .
    git config user.email t@t; git config user.name t
    git config core.hooksPath /dev/null
    mkdir -p docs scripts
    # docs/3.0-tools.md must exist: rule 2 reads it, and check-docs is skipped
    # by keeping every fixture free of markdown.
    printf 'x\n' > docs/3.0-tools.md
    git add -A; git commit -qm "app 0.0.0 api 0.0: base"
    git branch -M main
    for f in "$@"; do mkdir -p "$(dirname "$f")"; printf 'x\n' >> "$f"; git add "$f"; done
    "$HOOK" > /dev/null 2>&1
  ) || got=$?
  if [ "$got" -eq "$expect" ]; then
    echo "  ok       $desc"; PASS=$((PASS+1))
  else
    echo "  FAILED   $desc (expected exit $expect, got $got)"; FAIL=$((FAIL+1))
  fi
  rm -rf "$tmp"
}


# **Section 1b is about the branch, so `run_case` cannot express it**: every
# fixture there commits on `main`, which is the one branch 1b ignores.
run_branch_case() {
  local desc="$1" expect="$2" branch="$3"; shift 3
  local tmp got=0; tmp="$(mktemp -d)"
  (
    cd "$tmp"
    git init -q .
    git config user.email t@t; git config user.name t
    git config core.hooksPath /dev/null
    mkdir -p docs scripts
    printf 'x\n' > docs/3.0-tools.md
    git add -A; git commit -qm "app 0.0.0 api 0.0: base"
    git branch -M main
    [ "$branch" = main ] || git switch -q -c "$branch"
    for f in "$@"; do mkdir -p "$(dirname "$f")"; printf 'x\n' >> "$f"; git add "$f"; done
    "$HOOK" > /dev/null 2>&1
  ) || got=$?
  if [ "$got" -eq "$expect" ]; then
    echo "  ok       $desc"; PASS=$((PASS+1))
  else
    echo "  FAILED   $desc (expected exit $expect, got $got)"; FAIL=$((FAIL+1))
  fi
  rm -rf "$tmp"
}

# The version-bump exemption is about *which lines changed*, so `run_case`
# cannot express it: appending `x` to Cargo.toml produces a diff of `+x`, and a
# case built that way would pass or fail for a reason unrelated to the rule.
# These fixtures carry real content and edit it.
#
# Refusals also assert the *message*, not only the exit status. Every rule in
# the hook exits 1, so an exit code alone cannot tell "refused because it ships"
# from "refused because cargo is not installed in a temp directory" — which is
# how a batch of cases here once tested nothing at all.
run_bump_case() {
  local desc="$1" expect="$2" edit="$3" want="${4:-}"
  local tmp got=0 out; tmp="$(mktemp -d)"; out="$tmp/.out"
  (
    cd "$tmp"
    git init -q .
    git config user.email t@t; git config user.name t
    git config core.hooksPath /dev/null
    mkdir -p docs
    printf 'x\n' > docs/3.0-tools.md
    printf '[workspace.package]\nversion = "0.7.2"\nlicense = "MIT"\n' > Cargo.toml
    printf '[[package]]\nname = "api"\nversion = "0.7.2"\n' > Cargo.lock
    git add -A; git commit -qm "app 0.0.0 api 0.0: base"
    git branch -M main
    eval "$edit"
    "$HOOK" > "$out" 2>&1
  ) || got=$?
  if [ "$got" -ne "$expect" ]; then
    echo "  FAILED   $desc (expected exit $expect, got $got)"; FAIL=$((FAIL+1))
  elif [ -n "$want" ] && ! grep -q "$want" "$out" 2>/dev/null; then
    echo "  FAILED   $desc (exit $got, but the message was not about '$want')"; FAIL=$((FAIL+1))
  else
    echo "  ok       $desc"; PASS=$((PASS+1))
  fi
  rm -rf "$tmp"
}

echo "the post-deploy version bump on main (#316):"
run_bump_case "the bump deploy.sh writes" 0 '
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.toml
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.lock
  git add Cargo.toml Cargo.lock'
run_bump_case "Cargo.toml alone, version only" 0 '
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.toml
  git add Cargo.toml'
run_bump_case "a dependency added beside the bump" 1 '
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.toml
  printf "serde = \"1\"\n" >> Cargo.toml
  git add Cargo.toml' "changes what ships"
run_bump_case "a lockfile pulling a new crate" 1 '
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.toml
  printf "[[package]]\nname = \"serde\"\nversion = \"1.0.0\"\n" >> Cargo.lock
  git add Cargo.toml Cargo.lock' "changes what ships"
run_bump_case "a crate file smuggled in with the bump" 1 '
  sed -i "s/^version = \"0.7.2\"/version = \"0.7.3\"/" Cargo.toml
  mkdir -p crates/api/src && printf "fn x() {}\n" > crates/api/src/lib.rs
  git add Cargo.toml crates/api/src/lib.rs' "changes what ships"
run_bump_case "a licence change dressed as a bump" 1 '
  sed -i "s/^license = \"MIT\"/license = \"Apache-2.0\"/" Cargo.toml
  git add Cargo.toml' "changes what ships"
echo

echo "refused on main (ships in the image):"
run_case "a crate source file"            1 crates/server-game/src/lib.rs
run_case "Cargo.toml"                     1 Cargo.toml
run_case "Cargo.lock"                     1 Cargo.lock
run_case "the Dockerfile"                 1 Dockerfile
run_case "docker-compose.yml"             1 docker-compose.yml
run_case "the Caddyfile"                  1 Caddyfile
run_case ".dockerignore"                  1 .dockerignore
run_case ".cargo/config.toml"             1 .cargo/config.toml
run_case "a build asset nobody listed"    1 build-assets/nginx.conf
run_case "an unknown file at the root"    1 something-new.yml
run_case "old-crates, which the Dockerfile COPYs" 1 old-crates/first-try/src/main.rs
run_case "one shipping file among safe ones" 1 docs/x.txt crates/api/src/a.rs
# Data compiled in with include_str! ships as surely as the code does, and
# reads like content rather than source. Every one of these is a .txt.
run_case "a dictionary word list"         1 crates/rules-shared/src/sowpods.txt
run_case "the greylist"                   1 crates/rules-shared/src/wordlists/greylist.txt
run_case "the greylist stems it is built from" 1 crates/rules-shared/src/wordlists/greylist-stems.txt
run_case "an email template"              1 crates/server-game/emails/welcome.txt
run_case "a migration"                    1 crates/server-game/migrations/010_x.sql
# The reason wordlist-tools is a crate and not an example (#306): it writes a
# file that ships, so changing it is an image change even though it is a tool.
run_case "a word-list generator"          1 crates/wordlist-tools/src/bin/generate-greylist.rs

echo "registration rule:"
run_case "a new .claude hook, unregistered"   1 .claude/new-hook.sh
run_case "a new script, unregistered"         1 scripts/brand-new.sh

echo "rustfmt rule:"
# Three things have to be true for this to test anything, and the first version
# of it had none of them. The staged file must be one the image rule does not
# already refuse — so `examples/`, not `src/`. The fixture must have a
# `Cargo.toml`, or the hook's guard skips the check. And `cargo` must be stubbed,
# because what is under test is that the hook gates on the exit status, not
# rustfmt's own behaviour.
#
# Without all three the cases exited 1 from the image rule and passed while
# testing nothing — removing the refusal entirely left the suite green.
run_fmt_case() { # <desc> <expect> <cargo-exit> <file>
  local desc="$1" expect="$2" rc="$3" f="$4" tmp got=0
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    git init -q .; git config user.email t@t; git config user.name t
    git config core.hooksPath /dev/null
    mkdir -p docs bin
    printf 'x\n' > docs/3.0-tools.md
    printf '[workspace]\n' > Cargo.toml
    printf '#!/usr/bin/env bash\nif [ "$1" = fmt ]; then echo "Diff in /x/y.rs:1:"; exit %s; fi\nexit 0\n' "$rc" > bin/cargo
    chmod +x bin/cargo; export PATH="$tmp/bin:$PATH"
    git add -A; git commit -qm "app 0.0.0 api 0.0: base"; git branch -M main
    mkdir -p "$(dirname "$f")"; printf 'x\n' >> "$f"; git add "$f"
    "$HOOK" > /dev/null 2>&1
  ) || got=$?
  if [ "$got" -eq "$expect" ]; then echo "  ok       $desc"; PASS=$((PASS+1))
  else echo "  FAILED   $desc (expected $expect, got $got)"; FAIL=$((FAIL+1)); fi
  rm -rf "$tmp"
}
#              description                            expect  cargo  file
run_fmt_case "unformatted Rust is refused"                 1     1  crates/x/examples/a.rs
run_fmt_case "formatted Rust is allowed through"           0     0  crates/x/examples/a.rs
run_fmt_case "a markdown-only commit skips the check"      0     1  docs/notes.md

echo "allowed on main (does not ship):"
run_case "a script"                       0 scripts/thing.sh.tmp
run_case "an e2e test"                    0 e2e/login.spec.ts
run_case "a workflow"                     0 .github/workflows/ci.yml
run_case "a crate example"                0 crates/server-game/examples/bench.rs
run_case "a crate integration test"       0 crates/rules-shared/tests/words.rs

run_case "the gitignore"                  0 .gitignore
run_case "a README beside the word lists" 0 crates/rules-shared/src/wordlists/README.md

echo
echo "the process's own documents live on main (1b):"
# 2026-09-21: the ITIL rule, a CLAUDE.md clause and an obligations.py fix were
# all written onto 399-database-failure-status. commit-msg cannot catch it --
# a process edit carries no Refs, and a commit with no trailer is assumed to
# belong to the branch.
run_branch_case "CLAUDE.md on a project branch is refused"   1 399-x CLAUDE.md
run_branch_case "so is the lifecycle document"               1 399-x docs/3.6-change-lifecycle.md
run_branch_case "so is the workstreams document"             1 399-x docs/3.7-workstreams.md
run_branch_case "on main they are ordinary"                  0 main  CLAUDE.md
run_branch_case "a project's own document is fine on it"     0 399-x docs/4.3-api-schema.md
run_branch_case "and so is a script"                         0 399-x scripts/thing.sh.tmp
# 2026-09-25: docs/1.6 is generated from the branch's own headings, so it is
# regenerated on the branch after the rebase that precedes a merge. It was on
# the process list by mistake (docs/3.6, "Where a project has a branch").
run_branch_case "and so is the generated document map"       0 399-x docs/1.6-document-map.md

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
