#!/usr/bin/env bash
# shipping-paths.sh — which repository paths reach the image.
#
# Sourced by `.githooks/pre-commit` (the image rule, which refuses such a change
# on `main`) and by `deploy.sh` (the build manifest, which marks the commits
# that reach users). One definition in one file, for the reason
# `issue-mentions.sh` gives about itself: two copies is how the same defect
# comes to exist in two places, and this one decides both whether a commit is
# refused and whether a release is described correctly.
#
# **`docs/4.8` is the authority**, under *The route an artefact takes*: anything
# built into the image is Production Release — `crates/**`, the word lists,
# `Caddyfile`, `docker-compose.yml`, `Dockerfile` — and everything else in the
# repository is Repository Change. This is that rule in the form a script can
# apply, written as the *exceptions* rather than the members: the list of things
# that ship grows whenever a crate is added, and the list of things that do not
# is stable.
#
# Test code is excluded deliberately — `docs/4.8`, *What counts as an artefact*:
# a test exists to hold an artefact to its behaviour and is delivered with it.

# shellcheck disable=SC2034  # consumed by the sourcing script
# `.cargo/audit.toml` and not `.cargo/` — the file, deliberately. It configures
# `cargo audit` and is read by nothing else, so it cannot reach a build.
# `.cargo/config.toml` sets rustflags, the target directory and registries, and
# would change the bytes; a directory-wide exception would let that onto `main`
# with no branch. Added 2026-09-10, when the image rule refused #374 and was
# right to ask. `docs/4.8` carries the same split.
NON_SHIPPING='^(docs/|scripts/|e2e/|\.github/|\.githooks/|\.claude/|\.cargo/audit\.toml$|crates/[^/]+/(examples|tests|benches)/|LICENSE|\.gitignore$|\.markdownlint|.*\.md$)'

# touches_image <commit-ish> -> 0 if any path it changed reaches the image.
#
# `--name-only` against a single commit, so a merge is compared against its
# first parent — which is what "did this commit change the image" means to
# somebody reading a range.
touches_image() {
  local sha="$1" changed
  # `</dev/null` because this runs inside `while read` loops in deploy.sh, and a
  # git command that inherits the loop's stdin consumes the lines it has not
  # read yet. The manifest printed three of ten issues before this was added,
  # and printed them correctly — a truncation that looks like a filter working.
  # `-C "${REPO_DIR:-.}"` because deploy.sh addresses its repository explicitly
  # everywhere else and this must agree with it. Bare `git` reads the current
  # directory, which is the right repo when the hook runs and the wrong one
  # whenever the caller is working against another — including under test,
  # where it inspected the real repository instead of the fixture and marked
  # nothing as reaching the image. A manifest that says "no commit touches the
  # image" is a plausible answer, which is what makes it dangerous.
  changed="$(git -C "${REPO_DIR:-.}" show --name-only --format= "$sha" </dev/null 2>/dev/null | grep -v '^$' || true)"
  [[ -n "$changed" ]] || return 1
  printf '%s\n' "$changed" | grep -qvE "$NON_SHIPPING"
}
