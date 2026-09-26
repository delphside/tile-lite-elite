"""Which documents are process documents — decided once.

Owner, 2026-09-25: a process document describes the programme and how it
operates; a technical document describes the application. The technical ones
change with the code, on the project branch. The process ones belong to no
project, so they change on `main`: a copy on a branch disagrees with `main`
until it merges, and makes the process wait on a project it has nothing to do
with. `.githooks/pre-commit` asks here before committing one on a branch.

`docs/1.6` is not one: it is generated from the headings of the branch it is
built on, and regenerated there after the rebase that precedes a merge.

Owned here since 2026-09-26; the list was the hook's own `PROCESS_DOCS`, and
three documents repeated it in prose (#421). Pure: paths in, answers out.
"""

from __future__ import annotations

from typing import Iterable

PROCESS_DOCUMENTS = (
    "CLAUDE.md",
    "docs/3.6-change-lifecycle.md",
    "docs/3.7-workstreams.md",
)


def is_process_document(path: str) -> bool:
    return path in PROCESS_DOCUMENTS


def process_documents(paths: Iterable[str]) -> list[str]:
    """The paths, of these, that are process documents, in the order given."""
    return [p for p in paths if p and is_process_document(p)]
