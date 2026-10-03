#!/usr/bin/env python3
"""check-doc-links.py — every `](#anchor)` in the documentation resolves.

Why this exists: #137 renumbered every heading in `docs/3.3`, which changed
every anchor GitHub generates from those headings. **53 links inside the
document and 28 from other documents broke at once**, and none of them errors —
a bad anchor is a link that quietly lands the reader at the top of the page.
They were caught because a script was written that afternoon; nothing would have
caught the next one.

Checks two things across `docs/**/*.md` and the repository's own `*.md`:

  - `](#anchor)`            resolves to a heading in the same file
  - `](other.md#anchor)`    the file exists and holds that heading

Anchors are generated the way GitHub does it: lowercase, punctuation dropped,
spaces to hyphens. Headings inside fenced code blocks are not headings.

Exits non-zero and lists every break. Run by `scripts/check-docs.sh`, which is
what CI runs, so the check you make by hand and the one the pull request
enforces are the same code.
"""
import glob
import pathlib
import re
import sys


def slug(text: str) -> str:
    return re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", text.strip().lower()))


def headings(path: pathlib.Path) -> set[str]:
    out, fence = set(), False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if line.startswith("```"):
            fence = not fence
            continue
        m = re.match(r"^#{1,6} (.*)$", line) if not fence else None
        if m:
            out.add(slug(m.group(1)))
    return out


def main() -> int:
    files = sorted(glob.glob("docs/**/*.md", recursive=True) + glob.glob("*.md"))
    broken = []
    for name in files:
        path = pathlib.Path(name)
        own = headings(path)
        text = path.read_text(encoding="utf-8")
        # Inline code is an example, not a link. `docs/3.0` describes this very
        # check with a literal `](#anchor)` in a table cell, and without this the
        # checker read its own documentation as a broken link — the second time
        # in a day that documenting a convention broke the tool that reads it.
        text = re.sub(r"`[^`\n]*`", "``", text)
        for m in re.finditer(r"\]\(([^)\s]+)?#([a-zA-Z0-9_-]+)\)", text):
            target, anchor = m.group(1), m.group(2).lower()
            if target is None:
                if anchor not in own:
                    broken.append(f"{name}: #{anchor} — no such heading here")
            elif target.endswith(".md"):
                other = (path.parent / target).resolve()
                if not other.exists():
                    broken.append(f"{name}: {target} — no such file")
                elif anchor not in headings(other):
                    broken.append(f"{name}: {target}#{anchor} — no such heading there")

        # A link to a document with no anchor was not checked at all until
        # 2026-08-21, when `docs/3.3` gained a link to `4.8-artefacts.md` before
        # the file existed and this reported "all anchors resolve". The anchor
        # half was always the interesting case, which is how the plain half came
        # to be missed — and a link to a file that is not there is the more
        # obvious defect of the two.
        for m in re.finditer(r"\]\(([^)\s#]+\.md)\)", text):
            other = (path.parent / m.group(1)).resolve()
            if not other.exists():
                broken.append(f"{name}: {m.group(1)} — no such file")

    print(f"link check: {len(files)} files")
    for line in broken:
        print(f"  BROKEN  {line}")
    if broken:
        print(f"\n{len(broken)} broken anchor(s).")
        return 1
    print("  all anchors resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())
