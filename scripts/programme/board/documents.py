"""Which documents change on `main` and which ride a project branch — decided once.

Everything maintained is in one of three classes (docs/5.2, *Programme and
application*), and the class decides how it changes:

- **generic programme assets** (processes, role definitions, templates) and
- **programme records** (instances produced by operating the programme: the
  delivery log, the workstream list, reports, change notes) are `programme`.
  They belong to no project and change on `main`: a copy on a branch
  disagrees with `main` until it merges, and makes the programme wait on a
  project it has nothing to do with. `.githooks/pre-commit` asks here before
  committing one on a branch.
- **application assets** are `application`: their documents describe the
  application and change with its code, on the project branch. One committed
  to `main` is warned about, not refused (owner: keep some flexibility).

This answers the branch question only, which follows the class. It does not
say which `programme` documents are generic and which are records; docs/5.2
lists the generic assets and their instances.

Generated documents belong to neither: `docs/1.5` and `docs/1.6` are built
from whichever branch they are on, and regenerated there after the rebase that
precedes a merge. Pure: paths in, answers out.
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
