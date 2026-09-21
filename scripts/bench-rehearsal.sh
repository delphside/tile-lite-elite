#!/usr/bin/env bash
set -euo pipefail
# bench-rehearsal.sh — run the engine timing benchmark on rehearsal's hardware
# and record the row, as part of a release's technical tests.
#
# **A check, not a gate.** It prints the new row beside the last one for the
# same host and exits 0 either way. Timings move for reasons that are not
# regressions, and a threshold that failed a release on a noisy p99 would be
# routed around within two releases — so a person decides.
#
# **Rehearsal, not CI.** GitHub's runners are shared and their speed varies
# between runs, so a timing taken there cannot be compared with the one before
# it. Rehearsal is the same hardware as production, measured rather than
# assumed: both are AMD EPYC 7551, 2 cores, 954 MB.
#
# **Why the binary is copied.** Neither VM has a Rust toolchain and both run the
# same glibc as the development machine, so it is built here. `git` is not on
# the VM either, so the row comes back with `unknown` for the commit and this
# script substitutes the one the binary was actually built from.
#
# Raised by #291 R7. Usage: ./scripts/bench-rehearsal.sh [games]

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat <<'EOF'
usage: bench-rehearsal.sh [games] [edition]

Runs the engine timing benchmark on rehearsal's hardware and records
the row, as part of a release's technical tests. Defaults: 30 games,
the official edition.

A check, not a gate: it prints the new row beside the last one for the
same host and exits 0 either way. Timings move for reasons that are
not regressions, and a threshold that failed a release on a noisy p99
would be routed around within two releases. See the header comment
above for why rehearsal rather than CI (#291 R7, #304).

Refuses (exit 1) when:
  - fewer than 30 games are asked for
    -> "refusing <n> games: a p99 needs about 1200 samples, which is
        30 games"
    30 games yields about 1229 samples. The older 10-game runs gave a
    p99 from 411 samples, which is four data points.
  - the benchmark produces no `row:` line on the host
    -> "no row in the output — the benchmark did not complete:"
       followed by everything the run printed
EOF
  exit 0
fi

GAMES="${1:-30}"
EDITION="${2:-official}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV="$REPO/crates/server-game/examples/engine_timing_results.csv"
BIN="$REPO/target/release/examples/engine_timing_bench"

MOVES_DIR="$REPO/crates/server-game/examples/moves"
mkdir -p "$MOVES_DIR"

# shellcheck source=/dev/null
. "$REPO/scripts/rehearsal-target.sh"

SSH=(ssh -n -o BatchMode=yes -o ConnectTimeout=10)
[ -f "$DEPLOY_SSH_KEY" ] && SSH+=(-i "$DEPLOY_SSH_KEY")
TARGET="$DEPLOY_USER@$DEPLOY_HOST"

# 30 games is not arbitrary: it yields ~1229 samples, and the p99 of the older
# 10-game runs came from 411 samples, which is four data points.
if [ "$GAMES" -lt 30 ]; then
  echo "refusing $GAMES games: a p99 needs about 1200 samples, which is 30 games" >&2
  exit 1
fi

echo "==> building the benchmark"
cargo build --release --example engine_timing_bench -p server-game --quiet

COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
# What this tool writes is excluded from the dirty check — the results CSV and
# the per-move files — because a laptop run immediately before this one would
# otherwise label the rehearsal row `-dirty` when nothing about the code had
# changed. Everything else still counts.
if [ -n "$(git -C "$REPO" status --porcelain -- . \
    ':!crates/server-game/examples/engine_timing_results.csv' \
    ':!crates/server-game/examples/moves')" ]; then
  COMMIT="$COMMIT-dirty"
  echo "==> note: the tree is dirty, so the row records $COMMIT"
fi

# A reference run here, from the same binary, before the remote one. The
# comparison is only meaningful if both sides are the same code: pairing a VM
# run against a laptop run from a different commit would mix a machine
# difference with a code change and attribute the sum to whichever you were
# looking for. Building once and running both is what makes that impossible.
echo "==> reference run on this machine"
REF_BEFORE="$(ls "$MOVES_DIR" 2>/dev/null || true)"
"$BIN" "$GAMES" "$EDITION" > /dev/null
REF_FILE="$(ls -t "$MOVES_DIR"/*.csv 2>/dev/null | head -1)"

echo "==> copying to $DEPLOY_ENV ($DEPLOY_HOST)"
scp -q -o BatchMode=yes ${DEPLOY_SSH_KEY:+-i "$DEPLOY_SSH_KEY"} "$BIN" "$TARGET:/tmp/engine_timing_bench"

echo "==> running $GAMES games, $EDITION"
OUTPUT="$("${SSH[@]}" "$TARGET" "chmod +x /tmp/engine_timing_bench && cd /tmp && ./engine_timing_bench $GAMES $EDITION")"
"${SSH[@]}" "$TARGET" 'rm -f /tmp/engine_timing_bench' || true

# The VM has no CARGO_MANIFEST_DIR to write into, so the benchmark emits the
# per-move rows prefixed with MOVES and they are saved here instead. This is
# the raw data: one row per move, keyed by (game, turn), which is the same
# position on every machine because the games are seeded.
MOVES="$(printf '%s\n' "$OUTPUT" | sed -n 's/^MOVES //p')"

ROW="$(printf '%s\n' "$OUTPUT" | grep '^row: ' | sed 's/^row: //')"
if [ -z "$ROW" ]; then
  echo "no row in the output — the benchmark did not complete:" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi
ROW="${ROW/,unknown,/,$COMMIT,}"

HOST="$(printf '%s' "$ROW" | cut -d, -f3)"
PREVIOUS="$(grep ",$HOST," "$CSV" | tail -1 || true)"


printf '%s\n' "$ROW" >> "$CSV"
echo "==> recorded to ${CSV#"$REPO"/}"

if [ -n "$MOVES" ]; then
  RUN_TS="$(printf '%s' "$ROW" | cut -d, -f1)"
  SAFE_HOST="$(printf '%s' "$HOST" | tr -c 'A-Za-z0-9' '-')"
  MOVES_FILE="$MOVES_DIR/$RUN_TS-$SAFE_HOST.csv"
  printf '%s\n' "$MOVES" > "$MOVES_FILE"
  echo "==> per-move detail: ${MOVES_FILE#"$REPO"/} ($(( $(wc -l < "$MOVES_FILE") - 1 )) moves)"
fi
echo

# The comparison this exists for: the same host, then and now.
# median and p95 are the comparable numbers. The p99 on a shared VM is inside
# the moves the hypervisor descheduled — 27 of 1229 on 2026-09-04 — so it moves
# with the tenancy rather than with the code. `slow` counts moves over 20 ms,
# which is zero on hardware nobody else is sharing.
fmt() { printf '  %-15s median %6s   p95 %6s   p99 %7s   slow %3s (%s starved)\n' \
  "$(printf '%s' "$1" | cut -d, -f2)" "$(printf '%s' "$1" | cut -d, -f10)" \
  "$(printf '%s' "$1" | cut -d, -f13)" "$(printf '%s' "$1" | cut -d, -f14)" \
  "$(printf '%s' "$1" | cut -d, -f27)" "$(printf '%s' "$1" | cut -d, -f28)"; }
echo "$HOST:"
[ -n "$PREVIOUS" ] && fmt "$PREVIOUS" || echo "  (no previous run on this host)"
fmt "$ROW"
echo
if [ -n "${REF_FILE:-}" ] && [ -n "${MOVES_FILE:-}" ]; then
  echo
  echo "=== against this machine, outliers excluded ==="
  "$REPO/scripts/bench-compare.py" "$REF_FILE" "$MOVES_FILE" || true
fi

echo
echo "A check, not a gate: read the two rows and decide. Nothing here fails a release."
echo "Compare median and p95. A non-zero slow count is the hypervisor, and the p99"
echo "is inside it — see docs/2.3."
