#!/usr/bin/env bash
set -uo pipefail

# check-docs.sh — the documentation's own gate: lint, links, and placement.
#
# 3.3's rule, applied to itself: *"wherever a rule can be checked by the
# tooling, check it there — a rule in a document is advisory; a rule in a gate
# is real."* Every check here was being run by hand, which means run when
# remembered, which is how #137 shipped 81 broken anchors into a branch and
# found them by luck.
#
# One script, called by `.github/workflows/docs.yml`, so the check you make
# before pushing and the one the pull request enforces are the same code — the
# same reason `ci-status.sh` is shared between `deploy.sh` and the terminal.
#
# Three checks, each reported separately and all of them run even when an
# earlier one fails, because "fix one, discover the next" wastes a lap:
#
#   1. markdownlint  — the house style in .markdownlint.jsonc
#   2. links         — every `](#anchor)` resolves (scripts/check-doc-links.py)
#   3. placement     — the folder convention settled on #156
#
# Exits non-zero if any check failed.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
FAILED=0

# Pinned, and the same globs CI used before this script existed — the linter is
# otherwise "whatever is in one machine's npx cache", which is not a dependency
# anybody declared.
bold "1. markdownlint"
npx --yes markdownlint-cli2@0.23.2 "**/*.md" "#target" "#e2e/node_modules" "#old-crates" "#pipeline.md" 2>&1 | tail -4 || FAILED=1

bold "2. links"
python3 scripts/check-doc-links.py || FAILED=1

# The convention (#156): design documents live in an issue folder named for the
# issue that owns them — or for the parent issue where there is a workstream —
# and testing documents live in a release folder. Both under docs/changes/.
#
# The five files already in the flat directory stay there: GitHub does not
# follow a rename and several issue comments point at them. They are listed
# rather than pattern-matched so that the list can only shrink.
#
# Two of them were renamed on 2026-08-21 when *test plan* became *test design
# specification* — which broke exactly the links this list was protecting. The
# reason for grandfathering those two is therefore spent: the cost has been
# paid, so they should move into the convention's folders when the folder move
# happens rather than being protected from a second rename that now costs
# nothing.
bold "3. placement"
GRANDFATHERED=(
  "docs/changes/README.md"
  "docs/changes/0.6.0-user-testing.md"
  "docs/changes/25-rate-limiting-test-design.md"
  "docs/changes/41-user-deletion-test-design.md"
  "docs/changes/glossary-draft-2026-08-15.md"
)
STRAY=0
while IFS= read -r file; do
  keep=0
  for old in "${GRANDFATHERED[@]}"; do [[ "$file" == "$old" ]] && keep=1 && break; done
  (( keep )) && continue
  echo "  STRAY   $file"
  echo "          → docs/changes/workstreams/<workstream>/<issue>-<name>/ for a design"
  echo "            docs/changes/releases/<version>/ for a testing document (#156)"
  STRAY=1
done < <(find docs/changes -maxdepth 1 -name '*.md' | sort)
if (( STRAY )); then
  FAILED=1
else
  echo "  every change document is in an issue or release folder"
fi

# 4. the document map is derived, so a stale one is always wrong and always
# fixed by regenerating. A **gate**, unlike step 5: there is no judgement in it
# and no writing to do, only `document-map.py --write`.
#
# It was wired into nothing until 2026-09-11 — not this script, not the
# pre-commit hook, not CI, not verify.sh — so `docs/1.6` went stale silently.
# Found by ticking #349's own box asking whether the map lists every heading:
# it did not, because the commit before it added ten and did not regenerate.
# A derived artefact with no check is the shape #326 and #340 are also about.
echo
bold "4. the document map"
if "$HERE/scripts/document-map.py" --check > /dev/null 2>&1; then
  echo "  docs/1.6 lists every heading in every document"
else
  echo "  STALE   docs/1.6-document-map.md"
  echo "          → run ./scripts/document-map.py --write and commit it"
  FAILED=1
fi

# 5. API errors — a **check**, not a gate, so it never sets FAILED. An error the
# document does not carry is a documentation debt, and a build must not go red
# over writing that has not happened yet (#329). It prints and exits 0; the
# number is what makes the debt visible.
echo
bold "5. API errors"
"$HERE/scripts/check-api-errors.py" 2>&1 | sed -n '2,$p' | sed 's/^/  /'

echo
if (( FAILED )); then
  bold "FAILED"
else
  bold "OK"
fi
exit "$FAILED"
