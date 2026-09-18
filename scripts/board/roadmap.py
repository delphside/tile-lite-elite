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


def draw(road: Roadmap) -> str:
    """The Mermaid, plus the caption that says what the picture cannot."""
    out = ["```mermaid", "flowchart LR"]

    for index, (lane, issues) in enumerate(road.lanes.items()):
        out.append(f'  subgraph lane{index}["{_clean(lane, 40)}"]')
        out.append("    direction LR")
        for issue in issues:
            milestone = issue.raw.milestone or "milestone not set"
            phase = issue.step or "phase not set"
            label = (f"#{issue.number} {_clean(issue.title, 46)}"
                     f"<br/><i>{_clean(milestone, 20)} · {_clean(phase, 24)}</i>")
            out.append(f'    n{issue.number}["{label}"]:::{_band(issue.step)}')
        out.append("  end")

    for f, t in road.edges:
        out.append(f"  n{f} --> n{t}")

    out += [
        "  classDef planned fill:#eef2f7,stroke:#8895a7,color:#111",
        "  classDef designing fill:#e6efff,stroke:#5b7fbd,color:#111",
        "  classDef building fill:#fff4d6,stroke:#c99700,color:#111",
        "  classDef landed fill:#e4f4e4,stroke:#4c9a4c,color:#111",
        "```",
    ]

    plural = "y" if road.deliveries == 1 else "ies"
    caption = [
        "",
        f"*{road.deliveries} deliver{plural} in {len(road.lanes)} workstream"
        f"{'' if len(road.lanes) == 1 else 's'}. "
        f"{road.recorded} dependenc"
        f"{'y' if road.recorded == 1 else 'ies'} recorded and drawn as "
        f"{len(road.edges)} arrow{'' if len(road.edges) == 1 else 's'}, so "
        f"{road.unsequenced} start at the left.*",
        "",
        "*No dates: a column is a position in the sequence, not a month. "
        "Column 0 means nothing recorded blocks it starting now. Parent "
        "projects carry no milestone and make no delivery, so they have no "
        "bar — their work packages do. Shading is Phase: "
        "planned, designing, building, landed.*",
    ]
    if road.lifted:
        caption.append("")
        caption.append(
            "*A dependency on a parent project is drawn against each delivery "
            "it makes, because that is what waiting for a parent means: "
            + ", ".join(f"#{b} → #{i}"
                          for b, i in sorted({(b, i) for b, i, _ in road.lifted}))
            + ".*")
    if road.cycles:
        caption.append("")
        caption.append("*Circular dependencies, which cannot be sequenced: "
                       + ", ".join(f"#{a} → #{b}" for a, b in road.cycles) + ".*")
    if road.dropped:
        caption.append("")
        caption.append(
            "*Recorded against something with no bar, so not drawn: "
            + ", ".join(f"#{b} → #{i}" for b, i in sorted(set(road.dropped)))
            + ".*")

    return "\n".join(out + caption)


def render(snapshot: Snapshot, parent: int | None = None,
           workstream: str | None = None) -> tuple[str, Roadmap]:
    road = build(snapshot, parent, workstream)
    return draw(road), road
