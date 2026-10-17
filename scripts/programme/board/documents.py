"""Which documents change on `main` and which ride a project branch — decided once.

Everything maintained is in one of three classes (the programme's docs/1.3, *Programme and
application*), and the class decides how it changes:

- **generic programme assets** (processes, role definitions, templates) and
- **programme records** (instances produced by operating the programme: the
  delivery log, the workstream list, the artefact register in the programme's 3.1.2,
  reports, change notes) are `programme`. Since #485 almost all of them are in the
  programme repository, which has its own `main`; what the application's repository
  still holds of them is the instruction files, the roadmap and its diagram, and the
  `programme/` submodule, whose pin is the programme's. They belong to no project and change on `main`: a copy on a
  branch disagrees with `main` until it merges, and makes the programme wait on a
  project it has nothing to do with. `.githooks/pre-commit` asks here before
  committing one on a branch.
- **application assets** are `application`: their documents describe the
  application and change with its code, on the project branch. One committed
  to `main` is warned about, not refused (owner: keep some flexibility).

This answers the branch question only, which follows the class. It does not
say which `programme` documents are generic and which are records; the programme's docs/1.3
lists the generic assets and their instances.

Generated documents belong to neither: they are built from whichever branch
they are on, and regenerated there after the rebase that precedes a merge. Pure:
paths in, answers out; the lists are the application's, in its technical profile.
"""

from __future__ import annotations

from typing import Iterable

from . import profile

PROGRAMME = "programme"
APPLICATION = "application"
GENERATED = "generated"


def kind(path: str) -> str | None:
    """`programme`, `application` or `generated`; None for a path that is not a document.

    The lists are the technical profile's `documents` table (the generated
    documents, and the application's own programme documents) combined with the
    programme file's (`profile.programme_documents`). Anything else
    under docs/, and the paths in `application_outside_docs`, is the application's.
    """
    spec = profile.technical()
    if path in spec.strings("documents.generated"):
        return GENERATED
    exact, prefixes = profile.programme_documents()
    if path in exact or path.startswith(tuple(prefixes)):
        return PROGRAMME
    if path in spec.strings("documents.application_outside_docs") or path.startswith("docs/"):
        return APPLICATION
    return None


def of_kind(which: str, paths: Iterable[str]) -> list[str]:
    """The paths, of these, that are documents of that kind, in the order given."""
    return [p for p in paths if p and kind(p) == which]
