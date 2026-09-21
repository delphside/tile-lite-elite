# 291 Design

**The capacity plan, and what it is measured against.** Started 2026-09-21,
when #291 reached `Design and Test Approach`. Owner, 2026-09-20: *"answer during
design. This project will need a design doc."*

## The plan is a table, and here is the first one

R1 asks for *what is consumed, against what ceiling, and what would have to
change before the ceiling is reached*. Measured on production, 2026-09-21:

| | consumed | ceiling | headroom |
| --- | --- | --- | --- |
| **memory** | 469 MB | 954 MB | 51% |
| — server container | 75 MB | | |
| — web container | 34 MB | | |
| **disk** | 6.1 GB | 45 GB | 86% |
| **journal** | 51 MB | 100 MB / 7 days | 49% |
| **CPU** | load 0.00 | 2 vCPU | effectively all of it |
| **games in the database** | 15 | *unbounded — see below* | not knowable |

**Nothing is close to a ceiling.** That is the useful result of measuring rather
than arguing: the work this project owes is not relief, it is knowing *which*
number moves first and what moves it.

## What actually grows, and the one that is unbounded

**`AppState::new` loads every game into a `HashMap` at boot** —
`persistence.rs:448`, `select id from games order by created_at desc`, no
`where` clause. So boot time and resident memory scale with the row count of
`games`, and the question is what bounds that count.

| status | swept by | bounded |
| --- | --- | --- |
| `finished`, `aborted` | `expire_old_terminal_games` — a week after `ended_at` | **yes** |
| `active` | `expire_overdue_turns` retires a seat past its move limit, ending the game | **yes, eventually** |
| **`waiting`** | **nothing** | **no** |

**Seven of production's fifteen games are `waiting`, with last activity 46 to 62
days ago.** A waiting game has no current seat, so the move-timeout sweep never
looks at it; it is not terminal, so the terminal sweep never looks at it either.
It will be loaded into memory at every boot for the life of the service.

**This is R5's real shape.** R5 says *memory and startup stop growing with
cumulative games played*, and the terminal sweep already handles the games people
finish. What grows without limit is the games people **start and abandon** — which
is the more common case, because abandoning costs nothing.

## What would have to change: nothing new. The rule exists and is unbuilt

**RET-3 already decides this**, in `docs/1.0-rules.md`:

> A game that never started runs a thirty-day countdown from its last activity.
> Seven days in, its creator is asked what to do with it, and the question stands
> until they answer or the countdown takes the game, so it may be answered on
> day eight or on day twenty-nine.

**So there is no threshold to choose and no sweep to design.** The build is
issue #68, *Retention for games that never started*, closed into #270 (`#71 WP C:
Additional Game Lifecycle`), where it sits decided and unbuilt alongside the
scheduler that #166 designed.

**What this project contributes is the measurement, not the answer.** R5 said
*memory and startup stop growing with cumulative games played*, and the useful
finding is which games those are: not the ones people finish, which the terminal
sweep already clears, but the ones people start and abandon, which is the more
common case because abandoning costs nothing. Seven of production's fifteen are
in exactly that state.

**Which makes R5 a dependency rather than a work item.** It is satisfied once
the Additional Game Lifecycle package builds RET-3, and #291 should say so
rather than carry a second design for the same rule. `#68` also records why it matters beyond tidiness: DEL-4 depends
on it, because an unanswered invitation lives only on an unstarted game and can
otherwise hold an account open indefinitely.

## R2 and R7 are one mechanism, and it does not exist

R2 wants the capacity plan reviewed on a recurrence; R7 wants benchmark timings
refreshed regularly. **Building two timers would be the mistake.** The repository
has exactly one recurrence today — a post-deployment review falling due after
`REVIEW_DUE_DAYS`, in the board model's `turn.py` — and it is specific to that.

**So the design question is what a recurrence is**, once, for both: a due date on
an issue, a marker object whose age an alarm watches (the shape `backup-to-oci.sh`
already uses), or a step in the release lap. The third is the cheapest and the
weakest — it recurs only as often as releases do, which is not a schedule.

**Not settled here.** It needs the owner, and it is the one open question this
document leaves.

## R4 produces a number that ages, and R1 is what makes it mean anything

Stress testing (#91) asks where the service breaks, by measurement. That
measurement is worth having only against the table above: *"registrations fail
at N per minute"* is a fact, and *"N is 40 times what the ceiling allows before
memory runs out"* is a plan. So R1 is first, and R4 is measured against it
rather than reported alone.

## R7's tooling exists; what it lacks is a trigger

Engine timing (#304) is delivered: the benchmark records CPU time, steal and a
stable host label, with laptop, rehearsal and production recorded at `8eb923b`.
**The gap R7 names is not the measurement, it is the five weeks after one.**
Production was benchmarked on 30 July at `636794a`, which contains the tiered
dictionary, and the numbers show the effect — 0.77 ms median before, 0.50 ms
after. No production run then happened between 30 July and 3 September, across
the 0.7.0 and 0.7.1 releases, so two releases shipped with no number from
production-class hardware.

**So the trigger belongs on the release.** Benchmarking at the moment of a known
performance change already happens; what has no trigger is the release itself.
Owner, 2026-09-04: make benchmarks part of the standard regression, which
attaches the run to something that happens anyway.

**One question that leaves open**, carried here from the issue body: does the
release-regression benchmark also cover `rules-shared`'s dictionary benchmarks?
They cost about 6 s of CPU against the engine benchmark's 2.6 s, so the answer
decides whether every regression run pays that. Owner's for the same reason the
threshold is.

## R5's shape, and why it is not a small fix

**Load games on demand rather than at boot** is the obvious answer, and what it
costs is a cache policy, an eviction rule and a change to how the engine reaches
a game. Expiring `waiting` games is the cheap half and is worth doing whichever
way this goes, because it removes rows that no policy should ever have to hold.

**It is not gated on the state rework (#71)**, although it touches the same
structure. Owner, 2026-09-02: *"a game-related requirement outside #71 must be
independent of it and doable at any time."* R5 changes *when* a game is loaded,
not *what* a game is.

## Out of scope, and why

**R6** — `Retry-After`'s margin — is a defect that happens to be capacity-shaped,
as the issue says. It needs no plan and no measurement: a chosen number replaces
one left over from rounding.

**The dictionary** is the largest single consumer of the server's 75 MB and it
does not grow: it is fixed at build time. It is a floor, not a slope.
