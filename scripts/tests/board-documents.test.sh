#!/usr/bin/env bash
set -euo pipefail

# board-documents.test.sh — which documents are process documents (#421).
#
# From the rule, owner 2026-09-25: the process documents describe the programme
# and change on main; technical documents change with the code; docs/1.6 is
# generated and belongs to neither.

cd "$(dirname "$0")/.."
failures=0
check() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi; }

got="$(printf '%s\n' CLAUDE.md docs/3.6-change-lifecycle.md docs/3.7-workstreams.md \
        docs/1.6-document-map.md docs/4.3-api-schema.md scripts/deploy.sh \
        | python3 board-documents.py process | tr '\n' ' ' | sed 's/ $//')"
check "the three process documents, and nothing else" \
      "CLAUDE.md docs/3.6-change-lifecycle.md docs/3.7-workstreams.md" "$got"
check "the generated map is not one" "" "$(echo docs/1.6-document-map.md | python3 board-documents.py process)"
check "a technical document is not one" "" "$(echo docs/4.3-api-schema.md | python3 board-documents.py process)"
set +e; python3 board-documents.py frobnicate >/dev/null 2>&1; rc=$?; set -e
check "an unknown command is refused" 2 "$rc"

if (( failures > 0 )); then echo "$failures failed"; exit 1; fi
echo "all passed"
