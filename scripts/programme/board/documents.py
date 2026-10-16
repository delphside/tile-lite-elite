"""Which documents change on `main` and which ride a project branch — decided once.

Everything maintained is in one of three classes (the programme's docs/1.3, *Programme and
application*), and the class decides how it changes:

- **generic programme assets** (processes, role definitions, templates) and
- **programme records** (instances produced by operating the programme: the
  delivery log, the workstream list, the artefact register in the programme's 3.1.2,
  reports, change notes) are `programme`. Since #485 almost all of them are in the
  programme repository, which has its own `main`; what this repository still holds
  of them is the instruction files (`CLAUDE.md`, `AGENTS.md`, the `docs/` index), the
  roadmap (`docs/4.1.4`) and its diagram, and the `programme/` submodule, whose pin
  is the programme's. They belong to no project and change on `main`: a copy on a
  branch disagrees with `main` until it merges, and makes the programme wait on a
  project it has nothing to do with. `.githooks/pre-commit` asks here before
  committing one on a branch.
- **application assets** are `application`: their documents describe the
  application and change with its code, on the project branch. One committed
  to `main` is warned about, not refused (owner: keep some flexibility).

This answers the branch question only, which follows the class. It does not
say which `programme` documents are generic and which are records; the programme's docs/1.3
lists the generic assets and their instances.

Generated documents belong to neither: `docs/4.1.5` and `docs/4.1.6` are built
from whichever branch they are on, and regenerated there after the rebase that
precedes a merge. Pure: paths in, answers out.
"""

from __future__ import annotations

from typing import Iterable

PROGRAMME = "programme"
APPLICATION = "application"
GENERATED = "generated"

GENERATED_DOCUMENTS = (
    "docs/4.1.5-work-in-progress.md",
    "docs/4.1.6-document-map.md",
)

# Exact paths, then prefixes. Anything else under docs/, and the root README,
# is the application's.
PROGRAMME_DOCUMENTS = (
    "CLAUDE.md",
    "AGENTS.md",
    "docs/README.md",
    "docs/diagrams/roadmap.svg",  # generated from the roadmap
    "programme",  # the submodule's pin: anything in the programme repository
)
PROGRAMME_PREFIXES = (
    "docs/4.1.4-",
    "programme/",
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
