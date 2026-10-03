#!/usr/bin/env python3
"""roadmap-diagram.py — R8: the roadmap as a Gantt without dates.

Workstreams are swimlanes, sequencing runs left to right, and the bars are
deliveries: work packages and standalone projects, the issues that carry a
delivery milestone. Parent projects deliver nothing and so have no bar.
Dependencies are drawn, because GitHub records them and the project board has
no column that can show them.

    scripts/roadmap-diagram.py                        # the whole roadmap
    scripts/roadmap-diagram.py --parent 71            # one project's packages
    scripts/roadmap-diagram.py --workstream "Client UI"
    scripts/roadmap-diagram.py --write                # into 1.5-work-in-progress
    scripts/roadmap-diagram.py --project 71           # one project's allocation

**Derived, never maintained.** Generated from the issues each time it is asked
for. A hand-drawn diagram is stale the first time something moves and stale in
a way nobody can see; this one cannot disagree with the data because it has no
independent existence — the same reasoning as docs/4.9's "change history is
derived from git".

Reads the board model, so "is this a delivery" is answered in one place
(`scripts/board/model.py`) rather than re-derived here. Design:
docs/changes/workstreams/delivery-tooling/383-one-board-model/
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from board.roadmap import caption, render       # noqa: E402
from board.sources import Unavailable, fetch    # noqa: E402

START = "<!-- roadmap-diagram:start -->"
END = "<!-- roadmap-diagram:end -->"


def write_between_markers(path: str, block: str) -> None:
    """Replace what is between the markers, leaving the rest of the file alone.

    The markers are the contract: everything between them is generated and will
    be overwritten, everything outside is written by a person. Refusing when
    they are absent is deliberate — a diagram appended to the wrong file, or
    silently replacing a document, is worse than not drawing one.
    """
    text = Path(path).read_text()
    if START not in text or END not in text:
        sys.exit(f"roadmap-diagram: {path} has no {START} / {END} markers")
    head, rest = text.split(START, 1)
    _, tail = rest.split(END, 1)
    Path(path).write_text(f"{head}{START}\n\n{block}\n\n{END}{tail}")


def write_into_issue(number: int, block: str) -> None:
    """Same contract as the file version: the markers are the boundary, and a
    body without them is refused rather than appended to. An issue body is
    edited by people, so overwriting one that never asked for a diagram would
    be worse than not drawing it."""
    body = subprocess.run(["gh", "issue", "view", str(number), "--json", "body",
                           "--jq", ".body"], capture_output=True, text=True).stdout
    if START not in body or END not in body:
        sys.exit(f"roadmap-diagram: #{number} has no {START} / {END} markers in its body")
    head, rest = body.split(START, 1)
    _, tail = rest.split(END, 1)
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as fh:
        fh.write(f"{head}{START}\n\n{block}\n\n{END}{tail}")
        path = fh.name
    out = subprocess.run(["gh", "issue", "edit", str(number), "--body-file", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"roadmap-diagram: could not update #{number}: {out.stderr.strip()}")


def project_diagram(number: int) -> str:
    """One project's insides: its packages, and the requirements each takes.

    A different picture from the roadmap and still driven by the project's own
    body, because the owner's decision (2026-09-02) is that the split lives in
    the design document: "allocating requirements to work packages can be done
    within the project ... they can be listed in the one project design
    document." So the document is the source and this is a view of it. If they
    disagree the document is right and this is wrong, which is the way round it
    should be.
    """
    body = subprocess.run(["gh", "issue", "view", str(number), "--json", "body",
                           "--jq", ".body"], capture_output=True, text=True).stdout
    out = subprocess.run(["gh", "issue", "view", str(number), "--json", "subIssues"],
                         capture_output=True, text=True)
    nodes = ((json.loads(out.stdout or "{}").get("subIssues") or {}).get("nodes") or [])
    titles = {n["number"]: n["title"] for n in nodes}

    # Rows read "| #253 no foreign keys | **#268 Core** | why |".
    rows = re.findall(r"^\|\s*#(\d+)[^|]*\|[^#|]*#(\d+)([^|]*)\|", body, re.M)
    packages: dict[str, list[tuple[int, str]]] = {}
    for req, pkg, name in rows:
        key = f"#{pkg} {name.strip().strip('*').strip()}".rstrip()
        packages.setdefault(key.strip(), []).append((int(req), titles.get(int(req), "")))

    lines = ["```mermaid", "flowchart TB"]
    if not packages:
        lines.append(f'  n{number}["#{number}: no allocation table found in the body"]')
        lines.append("```")
        return "\n".join(lines)
    for pkg, reqs in packages.items():
        pid = re.match(r"#(\d+)", pkg).group(1)
        lines.append(f'  subgraph p{pid}["{pkg}"]')
        for req, title in reqs:
            t = (title or "").replace('"', "'").replace("[", "(").replace("]", ")")
            lines.append(f'    r{req}["#{req} {t[:40]}"]')
        lines.append("  end")
    lines.append("```")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--parent", type=int, metavar="N",
                    help="only the work packages of project N")
    ap.add_argument("--workstream", metavar="NAME", help="only this swimlane")
    ap.add_argument("--project", type=int, metavar="N",
                    help="a different picture: one project's work packages as "
                         "boxes, with the requirements each is expected to "
                         "take, read from the table in its own body")
    ap.add_argument("--write-issue", type=int, metavar="N",
                    help="replace the block between the markers in issue N's "
                         "body, so the diagram lives with what it draws")
    ap.add_argument("--svg", metavar="FILE",
                    help="where the chart itself is written by --write. "
                         "Defaults to roadmap.svg beside the document")
    ap.add_argument("--write", metavar="FILE", nargs="?",
                    const="docs/1.5-work-in-progress.md",
                    help="replace the block between the roadmap-diagram markers "
                         "in FILE instead of printing. Defaults to "
                         "docs/1.5-work-in-progress.md, the document that "
                         "exists to be left open while working")
    args = ap.parse_args(argv)

    if args.project:
        block = project_diagram(args.project)
    else:
        try:
            # No bodies: this reads fields, milestones and dependencies and no
            # headings, and bodies are 2.7s of the 4.6s (sources.py).
            snapshot = fetch(states="OPEN", with_bodies=False)
        except Unavailable as exc:
            # A source that did not answer is not an empty roadmap.
            print(f"cannot say: {exc}", file=sys.stderr)
            return 2
        svg, road = render(snapshot, args.parent, args.workstream)
        if not road.deliveries:
            print("roadmap-diagram: nothing to draw with that filter", file=sys.stderr)
            return 1
        if not road.edges:
            print("note: no blocked-by relationships are recorded, so every "
                  "delivery can start now.\n      Set them on the issues "
                  "(GitHub's own dependencies) and run this again.",
                  file=sys.stderr)
        if not args.write and not args.write_issue:
            sys.stdout.write(svg + "\n")
            return 0
        # The chart is a file and the document points at it: GitHub renders an
        # `.svg` referenced from markdown, and `docs/` ships nothing, so it may
        # live on `main` like any other document.
        doc = Path(args.write or "docs/1.5-work-in-progress.md")
        target = Path(args.svg) if args.svg else doc.parent / "diagrams" / "roadmap.svg"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(svg)
        sys.stderr.write(f"roadmap-diagram: wrote {target}\n")
        rel = os.path.relpath(target, doc.parent)
        block = (f"![The roadmap: workstreams as swimlanes, sequencing left to "
                 f"right]({rel})\n\n{caption(road)}")

    if args.write_issue:
        write_into_issue(args.write_issue, block)
        sys.stderr.write(f"roadmap-diagram: updated #{args.write_issue}\n")
    elif args.write:
        write_between_markers(args.write, block)
        sys.stderr.write(f"roadmap-diagram: updated {args.write}\n")
    else:
        sys.stdout.write(block + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
