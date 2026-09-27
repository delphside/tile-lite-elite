#!/usr/bin/env python3
"""Count the phrases that mark mixed content in the numbered documents. #427 R8.

A numbered document states what is true now (docs/3.9). History, argument and
quotation belong in the issue or the commit, and each has a tell: a dated
attribution, "until 2026-...", "Added 2026-...", or the headings of a design
note ("next steps", "open questions"). The count is a measure, not a gate: a
line can use one of these phrases legitimately, so a person reads the list and
decides. It should fall as documents are restructured.

    doc-signals.py            the total, and the documents carrying any
    doc-signals.py --list     every matching line
    doc-signals.py --total    the number alone

Always exits 0.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

DATE = r"20\d\d-\d\d-\d\d"
SIGNALS = [
    ("design-note heading", re.compile(
        r"\b(first[- ]pass|original design|current status|next steps|"
        r"open questions|future enhancements)\b", re.I)),
    ("attributed quotation", re.compile(
        rf"\b[Oo]wner(, {DATE}|, same day|:\s*\*?\")")),
    ("dated change", re.compile(
        # Case-insensitive except "Created": a register row's "created
        # 2026-08-21" is data, a sentence opening "Created 2026-08-24" is not.
        rf"\b((?i:until|since|added|corrected|changed|renamed|decided|narrowed|"
        rf"moved|retired|deleted|removed)|Created) (on )?{DATE}")),
]

# Records whose dates are their content: the delivery log, and the generated map.
EXEMPT = {"4.9-delivery-log.md", "1.6-document-map.md"}


def documents(root: Path = ROOT) -> list[Path]:
    return sorted(p for p in (root / "docs").glob("[1-4].*.md")
                  if p.name not in EXEMPT)


def matches(text: str) -> list[tuple[int, str, str]]:
    """(line number, signal name, line) for each line carrying a signal."""
    found = []
    in_fence = False
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for name, pattern in SIGNALS:
            if pattern.search(line):
                found.append((n, name, line.strip()))
                break
    return found


def main(argv: list[str]) -> int:
    per_doc = {p: matches(p.read_text()) for p in documents()}
    total = sum(len(m) for m in per_doc.values())
    if "--total" in argv:
        print(total)
        return 0
    print(f"  {total} line(s) in the numbered documents carry a history signal")
    for path, found in per_doc.items():
        if not found:
            continue
        print(f"  {len(found):4d}  docs/{path.name}")
        if "--list" in argv:
            for n, name, line in found:
                print(f"          {n}: [{name}] {line[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
