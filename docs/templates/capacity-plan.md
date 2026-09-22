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

## What changed since last month

Omit in the first report. Otherwise: which rows moved, by how much, and whether
anything crossed a threshold that was not crossed before. **This is the part
that needs the series**, and the reason each month gets its own file.

## How this was measured

The commands, so the next one is comparable. Name who ran what, where a figure
needed production access.
