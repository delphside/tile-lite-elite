"""Which documents are the programme's and which the application's — decided once.

Owner, 2026-09-25: a process document describes the programme and how it
operates; a technical document describes the application. The technical ones
change with the code, on the project branch. The process ones belong to no
project, so they change on `main`: a copy on a branch disagrees with `main`
until it merges, and makes the process wait on a project it has nothing to do
with. `.githooks/pre-commit` asks here before committing one on a branch.

Owner, 2026-09-29/30 (#421 R5): every document is on one side or the other,
as the scripts are (docs/5.0), and the words are *programme* and
*application*. The programme's are the 5.x group, the root instructions, the
index, the roadmap and programme overviews, and everything outside the
numbered set: templates, reports, diagrams' standard and change notes. Change
notes stay on `main` even for a project with a branch, because branches are
now short-lived and many per project. An application document committed to
`main` is warned about, not refused (owner: keep some flexibility).

Generated documents belong to neither: `docs/1.5` and `docs/1.6` are built
from whichever branch they are on, and regenerated there after the rebase that
precedes a merge.

Owned here since 2026-09-26; the list was the hook's own `PROCESS_DOCUMENTS`,
and three documents repeated it in prose (#421). Pure: paths in, answers out.
"""

from __future__ import annotations

from typing import Iterable

PROGRAMME = "programme"
APPLICATION = "application"
GENERATED = "generated"

GENERATED_DOCUMENTS = (
    "docs/1.5-work-in-progress.md",
    "docs/1.6-document-map.md",
)

# Exact paths, then prefixes. Anything else under docs/, and the root README,
# is the application's.
PROGRAMME_DOCUMENTS = (
    "CLAUDE.md",
    "AGENTS.md",
    "docs/README.md",
    "docs/programme-activity-log.csv",
)
PROGRAMME_PREFIXES = (
    "docs/1.4-",
    "docs/1.7-",
    "docs/5.",
    "docs/templates/",
    "docs/reports/",
    "docs/changes/",
    "docs/diagrams/",
)
APPLICATION_OUTSIDE_DOCS = (
    "README.md",
)


def kind(path: str) -> str | None:
    """`programme`, `application` or `generated`; None for a path that is not a document."""
    if path in GENERATED_DOCUMENTS:
        return GENERATED
    if path in PROGRAMME_DOCUMENTS or path.startswith(PROGRAMME_PREFIXES):
        return PROGRAMME
    if path in APPLICATION_OUTSIDE_DOCS or path.startswith("docs/"):
        return APPLICATION
    return None


def of_kind(which: str, paths: Iterable[str]) -> list[str]:
    """The paths, of these, that are documents of that kind, in the order given."""
    return [p for p in paths if p and kind(p) == which]
