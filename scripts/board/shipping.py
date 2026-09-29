"""What reaches the image — decided once.

**`docs/5.1` is the authority**, under *Route* in §2.15: anything
built into the image is Production Release — `crates/**`, the word lists,
`Caddyfile`, `docker-compose.yml`, `Dockerfile` — and everything else in the
repository is one of the two repository routes. This is that rule in the form code can apply,
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
from typing import Iterable, Sequence

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


_VERSION_LINE = re.compile(r'^[-+]version = "[0-9]+\.[0-9]+\.[0-9]+"$')


def version_bump_only(files: Sequence[str], changed_lines: Sequence[str]) -> bool:
    """Whether a change is nothing but the app version moving.

    The files are `Cargo.toml`, optionally with `Cargo.lock`, and every changed
    line in them is a `version = "X.Y.Z"` line. It is the one image change that
    belongs on `main` — the version bump after a production deploy, and the
    minor raised for a functional release (docs/3.3 §2.4) — and it ships no
    behaviour. No changed lines is *not* a bump: "nothing changed" must not read
    as "nothing disallowed changed".

    Owned here since 2026-09-26; it was the pre-commit hook's own function.
    """
    if sorted(f for f in files if f) not in (["Cargo.toml"], ["Cargo.lock", "Cargo.toml"]):
        return False
    lines = [line for line in changed_lines if line and not line.startswith(("+++", "---"))]
    return bool(lines) and all(_VERSION_LINE.match(line) for line in lines)


def ships(files: Sequence[str], changed_lines: Sequence[str]) -> bool:
    """Whether a change carries anything to release: it reaches the image, and it
    is more than the version moving. After a release `main` holds the next
    version's bump and nothing else, which ships nothing."""
    return touches_image(files) and not version_bump_only(files, changed_lines)

