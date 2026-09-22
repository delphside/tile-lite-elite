#!/usr/bin/env python3
"""capacity-chart.py — a bar chart per metric, with a trend and its ceiling.

    scripts/capacity-chart.py                 # every metric, to stdout as a list
    scripts/capacity-chart.py --write         # SVGs into the report's charts/
    scripts/capacity-chart.py --table         # the history table, as markdown
    scripts/capacity-chart.py --horizon 6     # periods to project (default 6)

**A capacity plan is read for its direction, not its figures.** #291 R1 asks
what is consumed against what ceiling; the owner's addition, 2026-09-22, is that
each report shows the trend and projects it: *"For each metric there should be a
bar chart with a regression line projected into the future and thresholds
marked."*

**Derived from `measurements.csv`, never drawn by hand.** The same reasoning as
`roadmap-diagram.py`: a chart maintained beside its data is stale the first time
the data moves, and stale in a way nobody can see. The reports are frozen once
written, but they are *rendered* from the series, so a report and its charts
cannot disagree.

**The regression is ordinary least squares over the measured points**, and it is
deliberately the dumbest thing that works. A capacity plan is read monthly by
one person; a fitted curve would imply a confidence nothing here has earned, and
the useful output is *"at this rate, this row meets its ceiling in March"* —
which a straight line answers and a better model would answer no more usefully
at six data points.

**A forecast without bounds is a forecast pretending to be a fact.** So the
projection is drawn as three lines: the fit, and a prediction interval either
side of it that *widens with distance*, because extrapolating six months from
six points is not as good as extrapolating one. The interval is the ordinary
one — `s * sqrt(1 + 1/n + (x - x̄)² / Sxx)` at 95% — and it needs at least three
points before there is any residual to measure.

**And every forecast carries a stated reliability**, because a straight line
through noise looks exactly like a straight line through a trend. The measure is
RRMSE — root mean square error over the mean — and the labels are *reliable*,
*possibly inaccurate* and *inaccurate*. **The form is the owner's prior art**: a
2012 capacity forecast that tabled each resource with its reliability, its value
at the end of the horizon, its forecast peak and its RRMSE, so a reader knew
which rows to believe. The thresholds below are ours and chosen, not derived
from it.

**One point is not a trend, and the chart says so** rather than drawing a
horizontal line through it, which would read as *flat* when the truth is
*unknown*. Two points fit a line exactly and have no residual at all, so they
get a trend with no interval and a reliability of *not enough data*.

Written to survive GitHub's SVG sanitiser, like `board/roadmap.py`:
presentation attributes only, no `<style>`, no `<defs>`, no `<marker>`, and an
opaque background because GitHub does not recolour an SVG under a dark theme.
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDER = ROOT / "docs" / "reports" / "capacity_plan"
DATA = FOLDER / "measurements.csv"
CHARTS = FOLDER / "charts"

# The roadmap's palette, so two generated diagrams in one repository look like
# one hand drew them.
INK, MUTED = "#111418", "#5a6472"
BAR, TREND, CEILING = "#3d6fb4", "#1f883d", "#cf222e"
BOUND = "#8fd19e"
GRID = "#d0d7de"

W, H = 560, 300
PAD_L, PAD_R, PAD_T, PAD_B = 62, 18, 34, 86


@dataclass(frozen=True)
class Series:
    metric: str
    unit: str
    ceiling: float | None
    periods: list[str]
    values: list[float]

    @property
    def slope(self) -> float | None:
        """Least squares, in units per period. `None` from a single point."""
        n = len(self.values)
        if n < 2:
            return None
        xs = list(range(n))
        mx = sum(xs) / n
        my = sum(self.values) / n
        denom = sum((x - mx) ** 2 for x in xs)
        if denom == 0:
            return None
        return sum((x - mx) * (y - my) for x, y in zip(xs, self.values)) / denom

    @property
    def intercept(self) -> float:
        n = len(self.values)
        slope = self.slope or 0.0
        return sum(self.values) / n - slope * (n - 1) / 2

    def at(self, index: float) -> float:
        return self.intercept + (self.slope or 0.0) * index

    @property
    def residual_sigma(self) -> float | None:
        """Standard error of the residuals. `None` below three points.

        Two points fit a line exactly: the residuals are zero and the interval
        would be zero-width, which is the most confident thing a chart can say
        and the least true.
        """
        n = len(self.values)
        if n < 3 or self.slope is None:
            return None
        rss = sum((y - self.at(i)) ** 2 for i, y in enumerate(self.values))
        return (rss / (n - 2)) ** 0.5

    @property
    def rrmse(self) -> float | None:
        """Root mean square error over the mean, as a fraction."""
        n = len(self.values)
        if n < 3 or self.slope is None:
            return None
        mean = sum(self.values) / n
        if mean == 0:
            return None
        rmse = (sum((y - self.at(i)) ** 2 for i, y in enumerate(self.values)) / n) ** 0.5
        return rmse / abs(mean)

    @property
    def reliability(self) -> str:
        """How much to believe the projection.

        Thresholds chosen here rather than derived: 5% and 15% of the mean are
        where a monthly capacity figure stops being worth planning against, at
        this size. Revisit them once there are a dozen reports to look back on.
        """
        if self.slope is None or self.rrmse is None:
            return "not enough data"
        if self.rrmse <= 0.05:
            return "reliable"
        if self.rrmse <= 0.15:
            return "possibly inaccurate"
        return "inaccurate"

    def interval(self, index: float) -> float:
        """Half-width of the 95% prediction interval at `index`.

        Widens with distance from the measured mean, which is the whole point:
        six periods out is a worse guess than one, and a constant band would
        say otherwise.
        """
        sigma = self.residual_sigma
        n = len(self.values)
        if sigma is None:
            return 0.0
        mx = (n - 1) / 2
        sxx = sum((x - mx) ** 2 for x in range(n))
        if sxx == 0:
            return 0.0
        return 1.96 * sigma * (1 + 1 / n + (index - mx) ** 2 / sxx) ** 0.5

    def crosses_at(self) -> int | None:
        """The period index where the trend meets the ceiling, if it ever does.

        `None` covers three different answers and the caller must say which:
        no ceiling, no trend, or a trend going the other way.
        """
        if self.ceiling is None or not self.slope or self.slope <= 0:
            return None
        if self.values[-1] >= self.ceiling:
            return len(self.values) - 1
        index = len(self.values) - 1
        while index < len(self.values) + 600:
            if self.at(index) >= self.ceiling:
                return index
            index += 1
        return None


def read(path: Path = DATA) -> list[Series]:
    rows = list(csv.DictReader(path.open()))
    order: list[str] = []
    by: dict[str, list[dict]] = {}
    for row in rows:
        metric = row["metric"]
        if metric not in by:
            by[metric] = []
            order.append(metric)
        by[metric].append(row)
    out = []
    for metric in order:
        group = sorted(by[metric], key=lambda r: r["period"])
        ceiling = group[-1]["ceiling"].strip()
        out.append(Series(
            metric=metric,
            unit=group[-1]["unit"],
            ceiling=float(ceiling) if ceiling else None,
            periods=[r["period"] for r in group],
            values=[float(r["value"]) for r in group],
        ))
    return out


def _esc(text: str) -> str:
    return (text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def _nice(value: float) -> str:
    """Enough digits to be read, never enough to imply precision.

    A projected 6.58857 GB claims five significant figures from a measurement
    that had two, which is the chart telling a lie about itself.
    """
    if abs(value) >= 10:
        return f"{value:.0f}"
    if abs(value) >= 1:
        return f"{value:.1f}".rstrip("0").rstrip(".")
    return f"{value:.2g}"


def draw(series: Series, horizon: int) -> str:
    n = len(series.values)
    slots = n + (horizon if series.slope else 0)
    top = max([*series.values, series.ceiling or 0,
               series.at(slots - 1) if series.slope else 0]) * 1.15 or 1.0

    plot_w = W - PAD_L - PAD_R
    plot_h = H - PAD_T - PAD_B
    step = plot_w / max(slots, 1)
    bar_w = max(6.0, step * 0.62)

    def x_of(i: float) -> float:
        return PAD_L + step * (i + 0.5)

    def y_of(v: float) -> float:
        return PAD_T + plot_h * (1 - v / top)

    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" font-family="-apple-system,BlinkMacSystemFont,'
           f'Segoe UI,Helvetica,Arial,sans-serif">',
           f'<rect width="{W}" height="{H}" fill="#ffffff"/>',
           f'<text x="{PAD_L}" y="20" font-size="13" font-weight="700" '
           f'fill="{INK}">{_esc(series.metric)} ({_esc(series.unit)})</text>']

    # Horizontal grid, four lines, labelled. Enough to read a value off the
    # chart and few enough not to fight the bars for attention.
    for k in range(5):
        v = top * k / 4
        y = y_of(v)
        out.append(f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{W - PAD_R}" '
                   f'y2="{y:.1f}" stroke="{GRID}" stroke-width="1"/>')
        out.append(f'<text x="{PAD_L - 6}" y="{y + 3.5:.1f}" text-anchor="end" '
                   f'font-size="9.5" fill="{MUTED}">{_nice(v)}</text>')

    # Measured bars.
    for i, v in enumerate(series.values):
        y = y_of(v)
        out.append(f'<rect x="{x_of(i) - bar_w / 2:.1f}" y="{y:.1f}" '
                   f'width="{bar_w:.1f}" height="{PAD_T + plot_h - y:.1f}" '
                   f'fill="{BAR}"/>')
        out.append(f'<text x="{x_of(i):.1f}" y="{y - 4:.1f}" '
                   f'text-anchor="middle" font-size="9.5" font-weight="600" '
                   f'fill="{INK}">{_nice(v)}</text>')

    # Period labels, thinned so they never collide.
    every = max(1, int(len(series.periods) / 8) + 1)
    for i, period in enumerate(series.periods):
        if i % every:
            continue
        out.append(f'<text x="{x_of(i):.1f}" y="{H - PAD_B + 16}" '
                   f'text-anchor="middle" font-size="9" fill="{MUTED}">'
                   f'{_esc(period[-2:] if "-" in period else period)}</text>')

    # The ceiling, and it is drawn even when nothing approaches it: a chart
    # whose threshold appears only once it matters teaches the reader that
    # there is no threshold.
    if series.ceiling is not None:
        y = y_of(series.ceiling)
        out.append(f'<line x1="{PAD_L}" y1="{y:.1f}" x2="{W - PAD_R}" '
                   f'y2="{y:.1f}" stroke="{CEILING}" stroke-width="1.5" '
                   f'stroke-dasharray="6 3"/>')
        out.append(f'<text x="{W - PAD_R}" y="{y - 5:.1f}" text-anchor="end" '
                   f'font-size="9.5" font-weight="600" fill="{CEILING}">'
                   f'ceiling {_nice(series.ceiling)}</text>')

    # The trend: solid over what was measured, dashed over what is projected,
    # so a reader is never invited to mistake one for the other.
    if series.slope is not None:
        y0, y1 = y_of(series.at(0)), y_of(series.at(n - 1))
        out.append(f'<line x1="{x_of(0):.1f}" y1="{y0:.1f}" '
                   f'x2="{x_of(n - 1):.1f}" y2="{y1:.1f}" stroke="{TREND}" '
                   f'stroke-width="2"/>')
        y2 = y_of(series.at(slots - 1))
        out.append(f'<line x1="{x_of(n - 1):.1f}" y1="{y1:.1f}" '
                   f'x2="{x_of(slots - 1):.1f}" y2="{y2:.1f}" stroke="{TREND}" '
                   f'stroke-width="2" stroke-dasharray="5 4"/>')

        # The prediction interval, as two dashed lines either side. Drawn as
        # polylines rather than straight segments because the band is a curve:
        # it widens with distance from the measured mean, and a straight edge
        # would flatten exactly the property it exists to show.
        if series.residual_sigma is not None:
            for sign in (1, -1):
                pts = []
                i = 0.0
                while i <= slots - 1 + 1e-9:
                    v = max(0.0, series.at(i) + sign * series.interval(i))
                    pts.append(f"{x_of(i):.1f},{min(max(y_of(v), PAD_T), PAD_T + plot_h):.1f}")
                    i += 0.5
                out.append(f'<polyline points="{" ".join(pts)}" fill="none" '
                           f'stroke="{BOUND}" stroke-width="1.2" '
                           f'stroke-dasharray="3 3"/>')

        out.append(f'<text x="{x_of(slots - 1):.1f}" y="{y2 - 6:.1f}" '
                   f'text-anchor="end" font-size="9.5" fill="{TREND}">'
                   f'{"rising" if series.slope > 0 else "falling"} '
                   f'{_nice(abs(series.slope))}/period</text>')
    else:
        out.append(f'<text x="{W / 2:.0f}" y="{PAD_T + plot_h / 2:.0f}" '
                   f'text-anchor="middle" font-size="11" font-style="italic" '
                   f'fill="{MUTED}">one measurement — no trend yet</text>')

    out.append(f'<line x1="{PAD_L}" y1="{PAD_T + plot_h}" x2="{W - PAD_R}" '
               f'y2="{PAD_T + plot_h}" stroke="{INK}" stroke-width="1"/>')

    # **A legend naming every series**, because a chart read six months later
    # is read by somebody who does not remember what green meant. The owner's
    # prior art names all four series in full under every chart.
    entries = [(BAR, "measured", "solid")]
    if series.slope is not None:
        entries.append((TREND, "trend, projected dashed", "line"))
        if series.residual_sigma is not None:
            entries.append((BOUND, "95% prediction interval", "dashed"))
    if series.ceiling is not None:
        entries.append((CEILING, f"ceiling {_nice(series.ceiling)} {series.unit}",
                        "dashed"))
    ly = H - PAD_B + 34
    for k, (colour, label, kind) in enumerate(entries):
        row, col = divmod(k, 2)
        lx = PAD_L + col * 250
        y = ly + row * 15
        if kind == "solid":
            out.append(f'<rect x="{lx}" y="{y - 6}" width="10" height="8" '
                       f'fill="{colour}"/>')
        else:
            dash = ' stroke-dasharray="3 3"' if kind == "dashed" else ""
            out.append(f'<line x1="{lx}" y1="{y - 2}" x2="{lx + 12}" '
                       f'y2="{y - 2}" stroke="{colour}" stroke-width="2"{dash}/>')
        out.append(f'<text x="{lx + 17}" y="{y + 1}" font-size="9" '
                   f'fill="{MUTED}">{_esc(label)}</text>')

    # Reliability, stated on the chart rather than only in the table: a
    # projection nobody should believe must say so where it is looked at.
    if series.slope is not None:
        note = series.reliability
        if series.rrmse is not None:
            note += f" · RRMSE {series.rrmse * 100:.1f}%"
        out.append(f'<text x="{W - PAD_R}" y="20" text-anchor="end" '
                   f'font-size="9.5" font-style="italic" fill="{MUTED}">'
                   f'{_esc(note)}</text>')

    out.append("</svg>")
    return "\n".join(out)


def verdict(series: Series, horizon: int) -> str:
    """One line per metric, saying what the chart shows."""
    if series.ceiling is None:
        ceiling = "no ceiling set"
    else:
        ceiling = f"ceiling {_nice(series.ceiling)} {series.unit}"
    if series.slope is None:
        return f"{series.metric}: one measurement, no trend. {ceiling}"
    direction = "rising" if series.slope > 0 else (
        "falling" if series.slope < 0 else "flat")
    crossing = series.crosses_at()
    if crossing is None:
        when = "not within the horizon" if series.ceiling else "no ceiling to meet"
    else:
        periods = crossing - (len(series.values) - 1)
        when = f"meets its ceiling in {periods} period(s)" if periods > 0 \
            else "already at or past its ceiling"
    return (f"{series.metric}: {direction} {_nice(abs(series.slope))} "
            f"{series.unit}/period, {ceiling} — {when}")


def summary(all_series: list[Series], horizon: int) -> str:
    """Every metric's forecast, with how much to believe it.

    **The form is the owner's prior art**: a 2012 capacity forecast tabled each
    resource with a reliability word, the value at the end of the horizon, the
    forecast peak and an RRMSE, so a reader could see at a glance which rows
    were worth planning against. A chart pack without this makes every
    projection look equally solid.
    """
    rows = ["| metric | forecast | value at +%d | peak | RRMSE | meets ceiling |"
            % horizon,
            "| --- | --- | --- | --- | --- | --- |"]
    for s in all_series:
        n = len(s.values)
        if s.slope is None:
            rows.append(f"| **{s.metric}** | not enough data | | | | |")
            continue
        end = s.at(n - 1 + horizon)
        peak = max(s.at(i) for i in range(n + horizon))
        rrmse = f"{s.rrmse * 100:.1f}%" if s.rrmse is not None else "—"
        crossing = s.crosses_at()
        if s.ceiling is None:
            when = "no ceiling set"
        elif crossing is None:
            when = "not within the horizon"
        else:
            periods = crossing - (n - 1)
            when = f"{periods} period(s)" if periods > 0 else "already past it"
        rows.append(f"| **{s.metric}** | {s.reliability} | "
                    f"{_nice(end)} {s.unit} | {_nice(peak)} {s.unit} | "
                    f"{rrmse} | {when} |")
    return "\n".join(rows)


def slug(metric: str) -> str:
    return metric.replace(" ", "-").lower()


def table(all_series: list[Series]) -> str:
    periods: list[str] = []
    for s in all_series:
        for p in s.periods:
            if p not in periods:
                periods.append(p)
    periods.sort()
    lines = ["| | " + " | ".join(periods) + " |",
             "| --- |" + " --- |" * len(periods)]
    for s in all_series:
        cells = []
        for p in periods:
            if p in s.periods:
                cells.append(f"{_nice(s.values[s.periods.index(p)])} {s.unit}")
            else:
                cells.append("")
        lines.append(f"| **{s.metric}** | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true",
                    help="write the SVGs into the report folder's charts/")
    ap.add_argument("--table", action="store_true",
                    help="print the history table as markdown")
    ap.add_argument("--summary", action="store_true",
                    help="print the forecast summary table as markdown")
    ap.add_argument("--horizon", type=int, default=6,
                    help="periods to project the trend (default 6)")
    args = ap.parse_args()

    if not DATA.exists():
        print(f"capacity-chart: {DATA} not found", file=sys.stderr)
        return 1
    all_series = read()

    if args.table:
        print(table(all_series))
        return 0

    if args.summary:
        print(summary(all_series, args.horizon))
        return 0

    if args.write:
        CHARTS.mkdir(parents=True, exist_ok=True)
        for s in all_series:
            (CHARTS / f"{slug(s.metric)}.svg").write_text(draw(s, args.horizon))
        print(f"==> {len(all_series)} chart(s) in "
              f"{CHARTS.relative_to(ROOT)}")

    for s in all_series:
        print(f"  {verdict(s, args.horizon)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
