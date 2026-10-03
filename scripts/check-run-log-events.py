#!/usr/bin/env python3
"""Every event a script writes is declared in docs/4.7 — #328 R2.

The server half of this already exists: `tests/log_schema.rs` and
`check-log-hygiene.py` hold it to its declaration. Without the equivalent the
script events drift within a month, and a record whose fields nobody declared
is a transcript rather than a log.

Reads `run_log_event "<message>"` calls out of `scripts/*.sh`, ignoring comment
lines, and requires each message to appear in `4.7`'s script table.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "docs" / "4.7-log-events.md"
CALL = re.compile(r'run_log_event\s+"([^"]+)"')


def written() -> dict[str, list[str]]:
    """message -> the scripts that write it, comments excluded."""
    out: dict[str, list[str]] = {}
    for path in sorted((ROOT / "scripts").glob("*.sh")):
        for line in path.read_text().splitlines():
            stripped = line.lstrip()
            # A comment showing the usage is not a call. The library's own
            # header carries one, and counting it reported an event nothing
            # writes.
            if stripped.startswith("#"):
                continue
            for m in CALL.finditer(line):
                out.setdefault(m.group(1), []).append(path.name)
    return out


def declared() -> set[str]:
    """Messages named in a table row of 4.7, as `| \\`name\\` | …`."""
    text = DOC.read_text()
    return {m.group(1) for m in re.finditer(r"^\|\s*`([^`]+)`\s*\|", text, re.M)}


def main() -> int:
    print("==> Script log events, against docs/4.7")
    events = written()
    known = declared()
    missing = {k: v for k, v in events.items() if k not in known}
    if not events:
        # Nothing writes an event. That is a fact about the scripts, not a pass
        # earned by the check -- say which it is.
        print("  no script writes a run-log event")
        return 0
    if not missing:
        print(f"  all {len(events)} event(s) the scripts write are declared")
        return 0
    print(f"  declared: {len(events) - len(missing)}    undeclared: {len(missing)}")
    for name, scripts in sorted(missing.items()):
        print(f"    {name:<28} {', '.join(sorted(set(scripts)))}")
    print()
    print("  An event nobody declared is a field nobody can rely on. Add it to")
    print("  docs/4.7's script table, with what it carries and why — #328 R2.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
