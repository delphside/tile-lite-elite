<!-- markdownlint-disable-file MD041 -->
<!--
Copy to `docs/reports/capacity_plan/<YYYY-MM>.md` and fill it in.

**Claude measures and writes it; Steve reviews it.** #291 R2, and the recurrence
that raises it is a date in #291's body — `Next capacity plan due: <date>`.
Doing this moves that date on a month.

**A report, not a document.** It records what was true on the day it was
measured and is never edited afterwards. Last month's is not superseded by this
month's: the series is what says whether a number is moving, which is the one
question a single measurement cannot answer. docs/3.6, "Which document goes
where".

**Named `TLE_CP_<yyyy>_<mm>.md`**, because a report gets mailed, pasted and
dropped on desktops, and the name has to mean something once it is off the
path.

**Where the numbers come from.** The application posts nothing — D49, because
the instance principal is a host credential. Host figures are read on the box;
games and accounts come from the admin CLI over loopback, which is the owner's
to run (CLAUDE.md, "Production access is the owner's to run").

Delete these comments as you go.
-->

# Capacity plan, *Month Year*

**Measured on production, *date*.** State here if anything was measured
elsewhere or estimated, and say which.

## What is consumed, against what ceiling

Every resource with a ceiling, and every resource without one — an absent
ceiling is a finding, not an omission.

| | consumed | ceiling | headroom |
| --- | --- | --- | --- |
| **memory** | | | |
| — server container | | | |
| — web container | | | |
| **disk** | | | |
| **journal** | | | |
| **CPU** | | | |
| **games in the database** | | | |
| **accounts** | | | |

One sentence on whether anything is close to a ceiling. If nothing is, say so
plainly: the value of the plan is knowing which number moves first, not
reporting relief.

## Which number moves first

The resource whose growth is least bounded, and what bounds it. Name the
mechanism, not the trend — a row that grows because nothing deletes it is a
different problem from one that grows with use.

Where a sweep or a rule is supposed to bound something and does not yet exist,
say which issue owns it.

## What would have to change before a ceiling is reached

| ceiling | reached by | what would have to change |
| --- | --- | --- |
| | | |

**Not a plan to do the work** — a statement of what the work would be, so a
decision to defer it is made knowingly.

## What is not known, and is the next thing worth measuring

The gaps. A resting measurement of an idle service says nothing about load, so
say so every time it is true rather than letting the table imply otherwise.

Anything with no ceiling set belongs here until somebody sets one.

## History, and where it is heading

**Carry enough history to see a trend and extrapolate from it** — one column per
period, most recent last, so the direction is visible without opening another
file.

**How far back depends on how often it is measured.** Twelve months is the outer
limit: enough to show a season, short enough that the table stays readable. If
the cadence ever tightens — weekly, say — keep the same number of *rows* rather
than the same number of months, because the table's job is to be read at a
glance.

Add the period's row to `measurements.csv`, then:

```bash
scripts/capacity-chart.py --table      # the history table below
scripts/capacity-chart.py --summary    # the forecast table below
scripts/capacity-chart.py --write      # the charts
```

Paste the history table here.

### What the forecast says, and how much to believe it

Paste the summary table here. **The reliability column is the one to read
first**: a straight line through noise looks exactly like a straight line
through a trend, and RRMSE is what tells them apart. A row marked *inaccurate*
should not be planned against — it should prompt either more measurements or a
question about why the metric is that volatile.

### Each metric, against its ceiling

**A chart per metric: bars for what was measured, a regression line projected
forward, and the ceiling marked.** Owner, 2026-09-22. Generated, never drawn —
a chart maintained beside its data is stale the first time the data moves and
stale in a way nobody can see.

| | |
| --- | --- |
| ![memory](charts/memory.svg) | ![disk](charts/disk.svg) |
| ![journal](charts/journal.svg) | ![games](charts/games.svg) |
| ![games waiting](charts/games-waiting.svg) | ![accounts](charts/accounts.svg) |

The ceiling is drawn even when nothing is near it: a threshold that appears only
once it matters teaches the reader there is no threshold.

**Then say what it means**, which the table cannot:

- which rows are moving, and whether the movement is use or accumulation — a
  number that grows because nothing deletes it is a different problem from one
  that grows with players
- for anything moving, **when it reaches its ceiling at this rate**, stated as a
  date or as *not within the horizon*. `capacity-chart.py` prints this line per
  metric; check it rather than reading it off the chart by eye
- whether any extrapolation here is worth acting on yet, and if not, what would
  change that

**A single measurement cannot answer any of this**, which is why the folder
keeps every report and why each one carries the window rather than only its own
column.

## Transaction thresholds and throttle limits

*Empty until #405 lands. Scaffolded now so the first report that can fill it
in has a shape to fill rather than a decision to make about where it goes.*

The six-step chain #405 builds: the hardware ceiling, the owner's utilisation
threshold, the workload threshold (the ceiling inverted into transactions per
second), the peak at the chosen service level, the owner's spike allowance,
and the throttle limits that follow.

**Recomputed every month, not derived once.** Owner, 2026-09-22: *"When we
have the numbers to do the analysis the report will include calculations of
transaction thresholds and throttling limits."* If a month's costs move, the
recomputed threshold disagrees with the limits actually configured, and that
disagreement is read here rather than discovered by an incident.

| step | this month |
| --- | --- |
| utilisation threshold (normal / degraded) | |
| workload threshold (transactions/s) | |
| peak, at the service level | |
| spike allowance | |

| limit | derived | configured | agree? |
| --- | --- | --- | --- |
| | | | |

## How this was measured

The commands, so the next one is comparable. Name who ran what, where a figure
needed production access.
