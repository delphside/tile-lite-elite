#!/usr/bin/env bats

# .githooks/pre-commit: the image rule refuses what ships and passes what does
# not, run as git runs it, a process of its own under its own set -euo pipefail.
#
# The rule is an allowlist of non-shipping paths, so the cases that matter most
# are the ones nobody listed: an unrecognised new file at the repository root
# must be refused, not waved through.

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert
  HOOK="$BATS_TEST_DIRNAME/../../.githooks/pre-commit"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" config core.hooksPath /dev/null
  mkdir -p "$R/docs"
  # docs/3.0-tools.md must exist: the registration rule reads it, and the docs
  # check is skipped by keeping every fixture free of other markdown.
  printf 'x\n' > "$R/docs/3.0-tools.md"
}

base() { git -C "$R" add -A; git -C "$R" commit -qm "app 0.0.0 api 0.0: base"; git -C "$R" branch -M main; }

# stage <file>...: append to each and stage it.
stage() {
  local f
  for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; printf 'x\n' >> "$R/$f"; git -C "$R" add "$f"; done
}

hook() { run bash -c 'cd "$1" && "$2"' _ "$R" "$HOOK"; }

# commit_on <branch> <file>...: a base on main, then the files staged on <branch>.
commit_on() {
  base
  [[ "$1" == main ]] || git -C "$R" switch -q -c "$1"
  stage "${@:2}"
  hook
}


# --- the post-deploy version bump on main (#316) ------------------------------
#
# The exemption is about which lines changed, so these fixtures carry real
# content and edit it: appending `x` to Cargo.toml would pass or fail for a
# reason unrelated to the rule. Refusals also assert the message, since every
# rule exits 1, and an exit code alone cannot tell "refused because it ships"
# from "refused because cargo is not installed in a temporary directory", which
# is how a batch of cases here once tested nothing at all.

bump_base() {
  printf '[workspace.package]\nversion = "0.7.2"\nlicense = "MIT"\n' > "$R/Cargo.toml"
  printf '[[package]]\nname = "api"\nversion = "0.7.2"\n' > "$R/Cargo.lock"
  base
}
bump() { sed -i 's/^version = "0.7.2"/version = "0.7.3"/' "$R/$1"; git -C "$R" add "$1"; }

@test "bump: the bump deploy.sh writes is allowed" {
  bump_base; bump Cargo.toml; bump Cargo.lock
  hook
  assert_success
}

@test "bump: Cargo.toml alone, version only, is allowed" {
  bump_base; bump Cargo.toml
  hook
  assert_success
}

@test "bump: a dependency added beside the bump is refused" {
  bump_base; bump Cargo.toml
  printf 'serde = "1"\n' >> "$R/Cargo.toml"; git -C "$R" add Cargo.toml
  hook
  assert_equal "$status" 1
  assert_output --partial "changes what ships"
}

@test "bump: a lockfile pulling a new crate is refused" {
  bump_base; bump Cargo.toml
  printf '[[package]]\nname = "serde"\nversion = "1.0.0"\n' >> "$R/Cargo.lock"; git -C "$R" add Cargo.lock
  hook
  assert_equal "$status" 1
  assert_output --partial "changes what ships"
}

@test "bump: a crate file smuggled in with the bump is refused" {
  bump_base; bump Cargo.toml
  mkdir -p "$R/crates/api/src"; printf 'fn x() {}\n' > "$R/crates/api/src/lib.rs"; git -C "$R" add crates/api/src/lib.rs
  hook
  assert_equal "$status" 1
  assert_output --partial "changes what ships"
}

@test "bump: a licence change dressed as a bump is refused" {
  bump_base
  sed -i 's/^license = "MIT"/license = "Apache-2.0"/' "$R/Cargo.toml"; git -C "$R" add Cargo.toml
  hook
  assert_equal "$status" 1
  assert_output --partial "changes what ships"
}

# --- the image rule, on main ----------------------------------------------------
# Data compiled in with include_str! ships as surely as the code does, and reads
# like content rather than source: the word lists and templates are .txt. The
# word-list generator is a crate and not an example (#306) because it writes a
# file that ships.

@test "a crate source file is refused on main" {
  commit_on main crates/server-game/src/lib.rs
  assert_equal "$status" 1
}

@test "Cargo.toml is refused on main" {
  commit_on main Cargo.toml
  assert_equal "$status" 1
}

@test "Cargo.lock is refused on main" {
  commit_on main Cargo.lock
  assert_equal "$status" 1
}

@test "the Dockerfile is refused on main" {
  commit_on main Dockerfile
  assert_equal "$status" 1
}

@test "docker-compose.yml is refused on main" {
  commit_on main docker-compose.yml
  assert_equal "$status" 1
}

@test "the Caddyfile is refused on main" {
  commit_on main Caddyfile
  assert_equal "$status" 1
}

@test ".dockerignore is refused on main" {
  commit_on main .dockerignore
  assert_equal "$status" 1
}

@test ".cargo/config.toml is refused on main" {
  commit_on main .cargo/config.toml
  assert_equal "$status" 1
}

@test "a build asset nobody listed is refused on main" {
  commit_on main build-assets/nginx.conf
  assert_equal "$status" 1
}

@test "an unknown file at the root is refused on main" {
  commit_on main something-new.yml
  assert_equal "$status" 1
}

@test "old-crates, which the Dockerfile COPYs is refused on main" {
  commit_on main old-crates/first-try/src/main.rs
  assert_equal "$status" 1
}

@test "one shipping file among safe ones is refused on main" {
  commit_on main docs/x.txt crates/api/src/a.rs
  assert_equal "$status" 1
}

@test "a dictionary word list is refused on main" {
  commit_on main crates/rules-shared/src/sowpods.txt
  assert_equal "$status" 1
}

@test "the greylist is refused on main" {
  commit_on main crates/rules-shared/src/wordlists/greylist.txt
  assert_equal "$status" 1
}

@test "the greylist stems it is built from is refused on main" {
  commit_on main crates/rules-shared/src/wordlists/greylist-stems.txt
  assert_equal "$status" 1
}

@test "an email template is refused on main" {
  commit_on main crates/server-game/emails/welcome.txt
  assert_equal "$status" 1
}

@test "a migration is refused on main" {
  commit_on main crates/server-game/migrations/010_x.sql
  assert_equal "$status" 1
}

@test "a word-list generator is refused on main" {
  commit_on main crates/wordlist-tools/src/bin/generate-greylist.rs
  assert_equal "$status" 1
}

@test "a new .claude hook, unregistered is refused on main" {
  commit_on main .claude/new-hook.sh
  assert_equal "$status" 1
}

@test "a new script, unregistered is refused on main" {
  commit_on main scripts/brand-new.sh
  assert_equal "$status" 1
}

@test "a script is allowed on main" {
  commit_on main scripts/thing.sh.tmp
  assert_success
}

@test "an e2e test is allowed on main" {
  commit_on main e2e/login.spec.ts
  assert_success
}

@test "a workflow is allowed on main" {
  commit_on main .github/workflows/ci.yml
  assert_success
}

@test "a crate example is allowed on main" {
  commit_on main crates/server-game/examples/bench.rs
  assert_success
}

@test "a crate integration test is allowed on main" {
  commit_on main crates/rules-shared/tests/words.rs
  assert_success
}

@test "the gitignore is allowed on main" {
  commit_on main .gitignore
  assert_success
}

@test "a README beside the word lists is allowed on main" {
  commit_on main crates/rules-shared/src/wordlists/README.md
  assert_success
}

# --- rustfmt ---------------------------------------------------------------------
# Three things have to be true for these to test anything, and the first version
# had none of them. The staged file must be one the image rule does not already
# refuse, so examples/, not src/. The fixture must have a Cargo.toml, or the
# hook's guard skips the check. And cargo must be stubbed, because what is under
# test is that the hook gates on the exit status, not rustfmt's own behaviour.
# Without all three the cases exited 1 from the image rule and passed while
# testing nothing.

fmt_case() {   # <cargo-fmt-exit> <file>
  printf '[workspace]\n' > "$R/Cargo.toml"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\nif [ "$1" = fmt ]; then echo "Diff in /x/y.rs:1:"; exit %s; fi\nexit 0\n' "$1" \
    > "$BATS_TEST_TMPDIR/bin/cargo"
  chmod +x "$BATS_TEST_TMPDIR/bin/cargo"
  base
  stage "$2"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" hook
}

@test "rustfmt: unformatted Rust is refused" {
  fmt_case 1 crates/x/examples/a.rs
  assert_equal "$status" 1
}

@test "rustfmt: formatted Rust is allowed through" {
  fmt_case 0 crates/x/examples/a.rs
  assert_success
}

@test "rustfmt: a markdown-only commit skips the check" {
  fmt_case 1 docs/notes.md
  assert_success
}

# --- the process's own documents live on main (1b) --------------------------------
# 2026-09-21: the ITIL rule, a CLAUDE.md clause and an obligations.py fix were
# all written onto 399-database-failure-status. commit-msg cannot catch it: a
# process edit carries no Refs. docs/1.6 is generated from the branch's own
# headings, so it is regenerated on the branch after the rebase before a merge.

@test "branch: CLAUDE.md on a project branch is refused" {
  commit_on 399-x CLAUDE.md
  assert_equal "$status" 1
}

@test "branch: so is the lifecycle document" {
  commit_on 399-x docs/3.6-change-lifecycle.md
  assert_equal "$status" 1
}

@test "branch: so is the workstreams document" {
  commit_on 399-x docs/3.7-workstreams.md
  assert_equal "$status" 1
}

@test "branch: on main they are ordinary" {
  commit_on main CLAUDE.md
  assert_success
}

@test "branch: a project's own document is fine on it" {
  commit_on 399-x docs/4.3-api-schema.md
  assert_success
}

@test "branch: and so is a script" {
  commit_on 399-x scripts/thing.sh.tmp
  assert_success
}

@test "branch: and so is the generated document map" {
  commit_on 399-x docs/1.6-document-map.md
  assert_success
}
