"""R8: the roadmap as a Gantt without dates.

Owner, 2026-09-18: *"essentially a gantt chart without dates, showing
sequencing and dependencies between work packages ... workstreams as swimlanes
and sequencing moving from left to right. Parent projects are not needed, only
work packages as they have an associated delivery milestone. Dependencies are
shown. Where sequencing is not know things can just start at the left."*

Four things follow from that, and each is a decision worth naming.

**No dates.** A Gantt needs a start and a target per bar and this programme has
neither by choice: `Q1`-`Q3` on Phase order what is next without inventing
dates (docs/4.8). So the x-axis is ordinal, not temporal — column *k* means
"nothing recorded stops this starting once *k* rounds of blockers are done",
not "month k".

**Deliveries only.** A parent project makes no delivery and carries no
milestone, so it has no bar. Its work packages do. A standalone project is
drawn for the same reason a work package is — it carries a Route and a
milestone, which is what `DELIVERING` means in `obligations.py`. The rule is
"has a delivery milestone", not "is called a work package".

**Dependencies are the only sequencing input.** GitHub records them
(`blockedBy`) and the project board has no column that can show them, which is
the whole reason this picture exists. Phase is *not* used to order columns:
being at Development says a thing has started, not that something else waits
on it.

**Unsequenced starts at the left.** A package with nothing recorded as
blocking it sits in column 0. With one dependency recorded across the whole
board today that is almost all of them, and the picture says so rather than
inventing an order to look busier.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from .model import Issue, ParentProject, StandaloneProject, WorkPackage, classify
from .sources import Snapshot

# Progress along a delivery, worst to best. Q1 is nearer than Q3, which is why
# they run backwards: the Phase field orders what is next (docs/4.8).
PHASE_ORDER = (
    "Scope", "Q3", "Q2", "Q1", "Design and Test Approach",
    "Development", "User testing", "Deployment",
    "Post-deployment", "Project Closedown",
)

# Four bands, so a bar reads as how far along it is at a glance.
BANDS = (
    ("planned", ("Scope", "Q3", "Q2", "Q1")),
    ("designing", ("Design and Test Approach",)),
    ("building", ("Development", "User testing", "Deployment")),
    ("landed", ("Post-deployment", "Project Closedown")),
)

DELIVERING = (WorkPackage, StandaloneProject)

TRIAGE_LANE = "no workstream set"


@dataclass
class Roadmap:
    """What was drawn, so the caller can report on it rather than guess."""

    lanes: dict[str, list[Issue]] = field(default_factory=dict)
    rank: dict[int, int] = field(default_factory=dict)
    edges: list[tuple[int, int]] = field(default_factory=list)
    recorded: int = 0
    lifted: list[tuple[int, int, int]] = field(default_factory=list)
    dropped: list[tuple[int, int]] = field(default_factory=list)
    cycles: list[tuple[int, int]] = field(default_factory=list)

    @property
    def deliveries(self) -> int:
        return sum(len(v) for v in self.lanes.values())

    @property
    def unsequenced(self) -> int:
        return sum(1 for r in self.rank.values() if r == 0)


def _band(phase: str | None) -> str:
    for name, phases in BANDS:
        if phase in phases:
            return name
    return "planned"


def _phase_index(phase: str | None) -> int:
    return PHASE_ORDER.index(phase) if phase in PHASE_ORDER else 0


def _clean(text: str, limit: int) -> str:
    """Mermaid ends a label on a quote or a bracket, so neither survives."""
    out = text.replace('"', "'").replace("[", "(").replace("]", ")")
    return out[: limit - 1] + "…" if len(out) > limit else out


def build(snapshot: Snapshot, parent: int | None = None,
          workstream: str | None = None) -> Roadmap:
    """Work out the lanes, the columns and the arrows. No drawing here."""
    issues = [classify(raw) for raw in snapshot.issues]
    by_number = {i.number: i for i in issues}

    drawn = [i for i in issues if isinstance(i, DELIVERING)]
    if parent is not None:
        drawn = [i for i in drawn if i.parent == parent]
    if workstream is not None:
        drawn = [i for i in drawn
                 if (i.field("Workstream") or "").lower() == workstream.lower()]
    drawn_numbers = {i.number for i in drawn}

    road = Roadmap()

    def expand(number: int) -> list[int]:
        """The bars a dependency on `number` really lands on.

        A parent has no bar, so being blocked by a parent means being blocked
        by every delivery it makes. That is the honest reading and it is why
        #10 sits to the right of all six One Game Model packages rather than
        losing its only recorded dependency to a node that is not drawn.
        """
        if number in drawn_numbers:
            return [number]
        target = by_number.get(number)
        if isinstance(target, ParentProject):
            return [n for n in target.work_packages if n in drawn_numbers]
        return []

    for issue in issues:
        for blocker in sorted(issue.blocked_by):
            road.recorded += 1
            froms, tos = expand(blocker), expand(issue.number)
            if not froms or not tos:
                if issue.number in drawn_numbers or blocker in drawn_numbers:
                    road.dropped.append((blocker, issue.number))
                continue
            for f in froms:
                for t in tos:
                    if f == t:
                        continue
                    road.edges.append((f, t))
                    if (f, t) != (blocker, issue.number):
                        road.lifted.append((blocker, issue.number, t))

    blockers: dict[int, set[int]] = {n: set() for n in drawn_numbers}
    for f, t in road.edges:
        blockers[t].add(f)

    # Longest path from a bar with nothing blocking it. A cycle cannot be
    # scheduled at all, so the back edge is cut and reported rather than
    # recursing until Python gives up.
    def rank_of(n: int, path: tuple[int, ...] = ()) -> int:
        if n in road.rank:
            return road.rank[n]
        if n in path:
            road.cycles.append((path[-1], n))
            return 0
        got = max((rank_of(b, path + (n,)) + 1 for b in blockers[n]), default=0)
        road.rank[n] = got
        return got

    for n in sorted(drawn_numbers):
        rank_of(n)

    for issue in drawn:
        lane = issue.field("Workstream") or TRIAGE_LANE
        road.lanes.setdefault(lane, []).append(issue)
    for lane in road.lanes.values():
        lane.sort(key=lambda i: (road.rank[i.number],
                                 -_phase_index(i.step), i.number))
    road.lanes = dict(sorted(road.lanes.items(),
                             key=lambda kv: (kv[0] == TRIAGE_LANE, kv[0])))
    road.edges = sorted(set(road.edges))
    return road


def _wrap(text: str, width_px: float, char_px: float, lines: int) -> list[str]:
    """Greedy wrap, because SVG has no flow layout and GitHub strips the
    foreignObject that would give us one. Measured in characters at an average
    advance, which is approximate and only has to be close: the bar is fixed
    width and the last line is clipped with an ellipsis if it overruns."""
    per_line = max(1, int(width_px / char_px))
    words, out, cur = text.split(), [], ""
    for word in words:
        trial = f"{cur} {word}".strip()
        if len(trial) <= per_line:
            cur = trial
            continue
        if cur:
            out.append(cur)
        cur = word
        if len(out) == lines:
            break
    if cur and len(out) < lines:
        out.append(cur)
    if not out:
        return [""]
    dropped = len(" ".join(out)) < len(text.rstrip())
    if dropped:
        last = out[-1]
        out[-1] = (last[: per_line - 1].rstrip() + "\u2026") if len(last) >= per_line - 1 \
            else last + "\u2026"
    return out


_TAG = re.compile(r"^#\d+\s+(WP [A-Z](?: Del \d+ of \d+)?):\s*(.*)$")


def _split_title(issue: Issue) -> tuple[str, str]:
    """`#297 WP B Del 2 of 2: the advisory check...` is two facts in one string.

    Which delivery of which parent belongs on the identifier line; the rest is
    what it actually does. Splitting them is what stops a bar wrapping to four
    lines of mostly punctuation.
    """
    match = _TAG.match(issue.title)
    if match:
        return f"#{issue.number} \u00b7 {match.group(1)}", match.group(2)
    return f"#{issue.number}", re.sub(r"^#\d+\s+", "", issue.title)


def _esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;"))


# Geometry. A bar is fixed width because a Gantt bar's width means duration,
# and this chart has no durations -- letting them vary would imply one.
PAD, GUTTER, HEADER = 16, 150, 34
BAR_W, BAR_H, COL_GAP, ROW_H = 224, 60, 46, 74

BAND = ("#ffffff", "#f6f8fa")
FILL = {"planned": ("#eef2f7", "#8895a7"), "designing": ("#e6efff", "#5b7fbd"),
        "building": ("#fff4d6", "#c99700"), "landed": ("#e4f4e4", "#4c9a4c")}
INK, MUTED, ARROW = "#111418", "#5a6472", "#3d6fb4"


def _rows(road: Roadmap) -> tuple[dict[int, tuple[int, int]], dict[str, int]]:
    """Give every bar a (row, column). Rows pack greedily within a lane.

    A chain stays on one row where the slots are free, which is what makes a
    sequence read as a sequence rather than as a staircase. Each bar occupies
    exactly one column, so two bars share a row whenever their columns differ.
    """
    place: dict[int, tuple[int, int]] = {}
    heights: dict[str, int] = {}
    for lane, issues in road.lanes.items():
        taken: list[set[int]] = []
        for issue in issues:
            col = road.rank[issue.number]
            row = next((r for r, used in enumerate(taken) if col not in used), len(taken))
            if row == len(taken):
                taken.append(set())
            taken[row].add(col)
            place[issue.number] = (row, col)
        heights[lane] = max(1, len(taken))
    return place, heights


def draw(road: Roadmap) -> str:
    """The chart as SVG.

    **Not Mermaid, and the reason is worth recording.** A `flowchart LR` with
    one `subgraph` per workstream is the obvious encoding and it does not
    work. Rendered and looked at: without `direction LR` a dependency is drawn
    top-to-bottom, which inverts the one thing the chart is for; with it, a
    single edge between two lanes makes dagre place the lanes *side by side*
    as columns instead of stacking them as bands, and the swimlanes are gone.
    That is not an edge case -- it is the board's shape today, where #10 waits
    on packages in two other workstreams. Mermaid has no swimlane primitive
    for flowcharts, so the grid is drawn here instead.

    Written to be safe through GitHub's SVG sanitiser: no `<style>`, no
    `<defs>`, no `<marker>`, no `foreignObject`. Presentation attributes only,
    arrowheads as explicit polygons, and an opaque background so the chart is
    readable under a dark theme, which GitHub does not recolour.
    """
    place, heights = _rows(road)
    ncols = max((c for _, c in place.values()), default=0) + 1
    width = PAD * 2 + GUTTER + ncols * BAR_W + max(0, ncols - 1) * COL_GAP
    height = PAD * 2 + HEADER + sum(heights.values()) * ROW_H

    def col_x(col: int) -> int:
        return PAD + GUTTER + col * (BAR_W + COL_GAP)

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
           f'height="{height}" viewBox="0 0 {width} {height}" '
           f'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif">',
           f'<rect width="{width}" height="{height}" fill="#ffffff"/>']

    # Column headers: what a column means, since it is not a date.
    for col in range(ncols):
        label = "can start now" if col == 0 else (
            "after 1 round" if col == 1 else f"after {col} rounds")
        out.append(f'<text x="{col_x(col) + BAR_W // 2}" y="{PAD + 20}" '
                   f'text-anchor="middle" font-size="11" font-weight="600" '
                   f'fill="{MUTED}">{_esc(label)}</text>')

    centre: dict[int, tuple[int, int, int]] = {}
    y = PAD + HEADER
    for index, (lane, issues) in enumerate(road.lanes.items()):
        band_h = heights[lane] * ROW_H
        out.append(f'<rect x="{PAD}" y="{y}" width="{width - PAD * 2}" '
                   f'height="{band_h}" fill="{BAND[index % 2]}"/>')
        out.append(f'<line x1="{PAD}" y1="{y}" x2="{width - PAD}" y2="{y}" '
                   f'stroke="#d8dee6" stroke-width="1"/>')
        for n, line in enumerate(_wrap(lane, GUTTER - 18, 6.0, 3)):
            out.append(f'<text x="{PAD + 10}" y="{y + band_h // 2 - 8 + n * 14}" '
                       f'font-size="11.5" font-weight="700" fill="{INK}">'
                       f'{_esc(line)}</text>')

        for issue in issues:
            row, col = place[issue.number]
            bx, by = col_x(col), y + row * ROW_H + (ROW_H - BAR_H) // 2
            fill, stroke = FILL[_band(issue.step)]
            out.append(f'<rect x="{bx}" y="{by}" width="{BAR_W}" height="{BAR_H}" '
                       f'rx="5" fill="{fill}" stroke="{stroke}" stroke-width="1"/>')
            ident, rest = _split_title(issue)
            out.append(f'<text x="{bx + 9}" y="{by + 15}" font-size="11" '
                       f'font-weight="700" fill="{INK}">{_esc(ident)}</text>')
            for n, line in enumerate(_wrap(rest, BAR_W - 18, 5.55, 2)):
                out.append(f'<text x="{bx + 9}" y="{by + 29 + n * 12}" '
                           f'font-size="10.5" fill="{INK}">{_esc(line)}</text>')
            meta = f"{issue.raw.milestone or 'milestone not set'} \u00b7 {issue.step or 'phase not set'}"
            out.append(f'<text x="{bx + 9}" y="{by + BAR_H - 7}" font-size="9.5" '
                       f'font-style="italic" fill="{MUTED}">'
                       f'{_esc(_wrap(meta, BAR_W - 18, 5.0, 1)[0])}</text>')
            centre[issue.number] = (bx, by + BAR_H // 2, bx + BAR_W)
        y += band_h

    out.append(f'<line x1="{PAD}" y1="{y}" x2="{width - PAD}" y2="{y}" '
               f'stroke="#d8dee6" stroke-width="1"/>')

    # Arrows last, so they sit above the bands.
    for source, target in road.edges:
        if source not in centre or target not in centre:
            continue
        _, sy, sx = centre[source]
        tx, ty, _ = centre[target]
        mid = sx + (tx - sx) / 2 if tx > sx else sx + COL_GAP / 2
        head = tx - 7
        path = (f"M {sx} {sy} H {mid} V {ty} H {head}" if abs(sy - ty) > 2
                else f"M {sx} {sy} H {head}")
        out.append(f'<path d="{path}" fill="none" stroke="{ARROW}" '
                   f'stroke-width="1.4" opacity="0.85"/>')
        out.append(f'<polygon points="{tx},{ty} {tx - 7},{ty - 3.6} '
                   f'{tx - 7},{ty + 3.6}" fill="{ARROW}"/>')

    out.append("</svg>")
    return "\n".join(out)


def caption(road: Roadmap) -> str:
    """The markdown that goes with the picture, saying what it cannot."""
    plural = "y" if road.deliveries == 1 else "ies"
    lines = [
        f"*{road.deliveries} deliver{plural} in {len(road.lanes)} workstream"
        f"{'' if len(road.lanes) == 1 else 's'}. "
        f"{road.recorded} dependenc{'y' if road.recorded == 1 else 'ies'} "
        f"recorded and drawn as {len(road.edges)} arrow"
        f"{'' if len(road.edges) == 1 else 's'}, so {road.unsequenced} "
        f"can start now.*",
        "",
        "*No dates: a column is a position in the sequence, not a month. "
        "Bars are all one width because a Gantt bar's width means duration, "
        "and this chart has none. Shading is Phase: planned, designing, "
        "building, landed.*",
    ]
    if road.lifted:
        lines += ["", "*A dependency on a parent project is drawn against each "
                  "delivery it makes, because that is what waiting for a parent "
                  "means: " + ", ".join(
                      f"#{b} \u2192 #{i}"
                      for b, i in sorted({(b, i) for b, i, _ in road.lifted})) + ".*"]
    if road.cycles:
        lines += ["", "*Circular dependencies, which cannot be sequenced: "
                  + ", ".join(f"#{a} \u2192 #{b}" for a, b in road.cycles) + ".*"]
    if road.dropped:
        lines += ["", "*Recorded against something with no bar, so not drawn: "
                  + ", ".join(f"#{b} \u2192 #{i}"
                              for b, i in sorted(set(road.dropped))) + ".*"]
    return "\n".join(lines)


def render(snapshot: Snapshot, parent: int | None = None,
           workstream: str | None = None) -> tuple[str, Roadmap]:
    road = build(snapshot, parent, workstream)
    return draw(road), road
