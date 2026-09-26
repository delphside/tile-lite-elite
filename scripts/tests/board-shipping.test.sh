#!/usr/bin/env bash
set -euo pipefail

# board-shipping.test.sh — what reaches the image, decided once (#421).
#
# The cases are docs/4.8's rule, not the pattern's: built into the image is a
# Production Release, and everything else is not. shipping-paths.test.sh keeps
# testing the functions the bash callers source, against real commits.

cd "$(dirname "$0")/.."

python3 - <<'PY'
import sys
sys.path.insert(0, ".")
from board.shipping import image_paths, reaches_image, ships, touches_image, version_bump_only

failures = 0
def expect(name, want, got):
    global failures
    if want == got:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n       want {want!r}\n       got  {got!r}")
        failures += 1

print("reaches the image")
for path in ("crates/server-game/src/app.rs", "crates/rules-shared/src/wordlists/greylist.txt",
             "Cargo.toml", "Cargo.lock", "Dockerfile", "Caddyfile", "docker-compose.yml",
             ".cargo/config.toml", "old-crates/first-try/src/main.rs"):
    expect(path, True, reaches_image(path))

print("does not")
for path in ("docs/3.3-testing-ci-and-release.md", "scripts/deploy.sh", "e2e/tests/smoke.spec.ts",
             ".github/workflows/ci.yml", ".githooks/pre-commit", ".claude/settings.json",
             ".cargo/audit.toml", "crates/server-game/examples/engine_timing_results.csv",
             "crates/server-game/tests/api.rs", "crates/engine-core/benches/b.rs",
             "crates/ui/README.md", "LICENSE", ".gitignore", ".markdownlint.json"):
    expect(path, False, reaches_image(path))

print("a change")
expect("one shipping path among many", ["Cargo.lock"], image_paths(["docs/a.md", "Cargo.lock", "scripts/x.sh"]))
expect("a change that touched nothing reaches nothing", False, touches_image([]))

print("a version bump")
bump = ['-version = "0.9.0"', '+version = "0.9.1"']
expect("Cargo.toml alone, version lines only", True, version_bump_only(["Cargo.toml"], bump))
expect("with Cargo.lock, version lines only", True, version_bump_only(["Cargo.lock", "Cargo.toml"], bump * 8))
expect("a dependency line is not a bump", False, version_bump_only(["Cargo.toml"], bump + ['+anyhow = "1"']))
expect("another file alongside is not a bump", False, version_bump_only(["Cargo.toml", "crates/api/src/lib.rs"], bump))
expect("no changed lines is not a bump", False, version_bump_only(["Cargo.toml"], []))
expect("a two-part version is not ours", False, version_bump_only(["Cargo.toml"], ['+version = "1.0"']))

print("ships")
expect("the post-release bump ships nothing", False, ships(["Cargo.lock", "Cargo.toml"], bump))
expect("a Dockerfile change ships", True, ships(["Dockerfile"], []))
expect("a document ships nothing", False, ships(["docs/a.md"], []))
expect("a crate change ships", True, ships(["crates/ui/src/app.rs"], []))
sys.exit(1 if failures else 0)
PY

echo "the command"
failures=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi; }
check "paths prints only the shipping ones" "Dockerfile" "$(printf 'docs/a.md\nDockerfile\n' | python3 board-shipping.py paths)"
set +e; python3 board-shipping.py commit no-such-commit >/dev/null 2>&1; rc=$?; set -e
check "an unknown commit changed nothing" 1 "$rc"
set +e; python3 board-shipping.py frobnicate >/dev/null 2>&1; rc=$?; set -e
check "an unknown command is refused" 2 "$rc"
if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
