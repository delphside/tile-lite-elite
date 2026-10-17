"""What reaches the image — decided once.

**`programme/docs/1.2-change-lifecycle.md` is the authority**, under *Route* in §2.15: anything
built into the image is Production Release, and everything else in the
repository is one of the two repository routes. This is that rule in the form
code can apply, written as the *exceptions* rather than the members: the list
of things that ship grows whenever a crate is added, and the list of things
that do not is stable.

**The list is the application's.** Since #485 stage 2 it is the technical
profile's `ships.non_shipping` (regular expressions, matched from the start of
a path), and a version-only bump is described by `versions.bump`; nothing here
names a path. Tile Lite Elite's reasons for each entry are in its profile's
comments and the application's artefact register (`3.n.2`),
*What counts as an artefact*: a test exists to hold an artefact to its
behaviour and is delivered with it.

**By path, and that is its limit.** A dependency added only for an example, or
lock-file lines for another platform, change the manifest and lock file and so
count as reaching the image though the bytes do not change (#404, #421).

Owned here since 2026-09-26; it was `shipping-paths.sh`'s `NON_SHIPPING`, which
now asks `scripts/programme/board/board-shipping.py` (#421). Paths in, answers
out; the profile is the only thing read.
"""

from __future__ import annotations

import re
from functools import lru_cache
from typing import Iterable, Sequence

from . import profile


@lru_cache(maxsize=8)
def _compiled(patterns: tuple[str, ...]) -> "re.Pattern[str]":
    return re.compile("^(" + "|".join(patterns) + ")")


def _non_shipping() -> "re.Pattern[str]":
    return _compiled(tuple(profile.technical().strings("ships.non_shipping")))


def reaches_image(path: str) -> bool:
    """Whether a repository path is built into, or shipped with, the image."""
    return not _non_shipping().match(path)


def image_paths(paths: Iterable[str]) -> list[str]:
    """The paths, of these, that reach the image, in the order given."""
    return [p for p in paths if p and reaches_image(p)]


def touches_image(paths: Iterable[str]) -> bool:
    """Whether a change to these paths reaches the image.

    No paths is *no*: a change that touched nothing changed nothing.
    """
    return bool(image_paths(paths))


def version_bump_only(files: Sequence[str], changed_lines: Sequence[str]) -> bool:
    """Whether a change is nothing but the app version moving.

    The files are the profile's `versions.bump.required`, optionally with the
    rest of `versions.bump.files`, and every changed line in them matches
    `versions.bump.line`. It is the one image change that belongs on `main` —
    the version bump after a production deploy, and the minor raised for a
    functional release (docs/4.3.3 §2.4) — and it ships no behaviour. No
    changed lines is *not* a bump: "nothing changed" must not read as
    "nothing disallowed changed".

    Owned here since 2026-09-26; it was the pre-commit hook's own function.
    """
    spec = profile.technical()
    required = spec.strings("versions.bump.required")
    allowed = spec.strings("versions.bump.files")
    line_pattern = re.compile(spec.string("versions.bump.line"))
    got = sorted(f for f in files if f)
    if not all(r in got for r in required) or any(f not in allowed for f in got):
        return False
    lines = [line for line in changed_lines if line and not line.startswith(("+++", "---"))]
    return bool(lines) and all(line_pattern.match(line) for line in lines)


def ships(files: Sequence[str], changed_lines: Sequence[str]) -> bool:
    """Whether a change carries anything to release: it reaches the image, and it
    is more than the version moving. After a release `main` holds the next
    version's bump and nothing else, which ships nothing."""
    return touches_image(files) and not version_bump_only(files, changed_lines)

