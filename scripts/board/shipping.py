"""What reaches the image — decided once.

**`docs/4.8` is the authority**, under *The route an artefact takes*: anything
built into the image is Production Release — `crates/**`, the word lists,
`Caddyfile`, `docker-compose.yml`, `Dockerfile` — and everything else in the
repository is Repository Change. This is that rule in the form code can apply,
written as the *exceptions* rather than the members: the list of things that
ship grows whenever a crate is added, and the list of things that do not is
stable.

Test code is excluded deliberately — `docs/4.8`, *What counts as an artefact*:
a test exists to hold an artefact to its behaviour and is delivered with it.
So are a crate's `examples/` and `benches/`, which are never compiled into the
binary; the release's own benchmark rows, under `examples/`, once passed for an
image change in a test that used a looser pattern (#421).

`.cargo/audit.toml` and not `.cargo/` — the file, deliberately. It configures
`cargo audit` and is read by nothing else, so it cannot reach a build.
`.cargo/config.toml` sets rustflags, the target directory and registries, and
would change the bytes.

**By path, and that is its limit.** A dependency added only for an example, or
lock-file lines for another platform, change `Cargo.toml` and `Cargo.lock` and
so count as reaching the image though the bytes do not change (#404, #421).

Owned here since 2026-09-26; it was `shipping-paths.sh`'s `NON_SHIPPING`, which
now asks `scripts/board-shipping.py` (#421). Pure: paths in, answers out.
"""

from __future__ import annotations

import re
from typing import Iterable

_NON_SHIPPING = re.compile(
    r"^(docs/|scripts/|e2e/|\.github/|\.githooks/|\.claude/|\.cargo/audit\.toml$"
    r"|crates/[^/]+/(examples|tests|benches)/|LICENSE|\.gitignore$|\.markdownlint|.*\.md$)"
)


def reaches_image(path: str) -> bool:
    """Whether a repository path is built into, or shipped with, the image."""
    return not _NON_SHIPPING.match(path)


def image_paths(paths: Iterable[str]) -> list[str]:
    """The paths, of these, that reach the image, in the order given."""
    return [p for p in paths if p and reaches_image(p)]


def touches_image(paths: Iterable[str]) -> bool:
    """Whether a change to these paths reaches the image.

    No paths is *no*: a change that touched nothing changed nothing.
    """
    return bool(image_paths(paths))
