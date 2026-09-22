# 291 Design

**The capacity plan, and what it is measured against.** Started 2026-09-21,
when #291 reached `Design and Test Approach`. Owner, 2026-09-20: *"answer during
design. This project will need a design doc."*

## The plan is a report, not a section of this document

Owner, 2026-09-22:

> The Capacity Plan needs a folder containing each month's plan. It is a report
> that is a product of the programme produced regularly. The numbered docs
> describe the programme and would be static if the programme didn't change.

**So the plan lives in `docs/reports/capacity_plan/`, one file per month**, and
this document keeps the argument rather than the numbers. The first is
[`TLE_CP_2026_09.md`](../../../../reports/capacity_plan/TLE_CP_2026_09.md),
measured on production 2026-09-21.

**That is a third kind of document and it did not exist before.** A numbered
`docs/N.N` describes the programme and changes when the programme does. A change
document under `docs/changes/` belongs to an issue and expires with it. A report
is neither: it is an output the programme produces on a cadence, and last
month's is not superseded by this month's — it is the series that carries the
meaning.

**What the first one found**, and it is what shaped the rest of this design:
nothing is close to a ceiling, and exactly one number is unbounded — the games
table, because `AppState::new` loads every game at boot and nothing sweeps a
game that never started. Seven of production's fifteen were in that state, idle
46 to 62 days.

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

## R2 and R7 are two mechanisms, and the argument for one was wrong

R2 wants the capacity plan reviewed on a recurrence; R7 wants benchmark timings
refreshed regularly. This document argued that building two timers would be the
mistake. **That was wrong**, and the owner said why on 2026-09-21:

> We are planning to introduce scheduled jobs. That would include some for
> capacity planning, such as the benchmarks. Reviewing the capacity plan requires
> Claude to update and Steve to review, so an issue date makes more sense.

**A job a machine runs and a review two people do are not one mechanism wearing
two hats.** The shared word *recurrence* hid a difference that matters: one has
to happen unattended and produce a number, the other has to reach a person and
wait for them.

| | mechanism | why |
| --- | --- | --- |
| **R7**, benchmark timings | a **scheduled job**, and a due date until there is one | it runs unattended, produces a row, and needs nobody |
| **R2**, the capacity plan review | a **due date on an issue** | Claude updates it, the owner reviews it. A job cannot do either half |

**R7 will be a scheduled job and is not blocked on becoming one.** Owner,
2026-09-22: *"The three game logic schedules. Capacity Planning schedules can be
run manually on an ad-hoc basis for now."* So #400 ships with the four game-logic
callers, and Capacity Planning's jobs — the benchmark run, the daily size
measurement, growth alerting — are run by hand until the mechanism is there to
move them onto.

**Which makes R7 a due date too, for now.** The same mechanism R2 uses: a line in
the issue body saying when the next run falls due, surfaced by the board. That is
a workaround for an absent scheduler and it should say so, so nobody later
mistakes it for the design — `docs/3.7` puts the mechanism in Application & Game
Architecture and the individual jobs with the workstream whose rule they apply,
and that does not change because the first few runs are manual.

**The difference between the two is then only who does the work**, and it is
worth keeping in view: R2's review needs Claude to update a document and the
owner to read it, and will always need both. R7's run needs nobody once there is
something to run it.

**R2 needs nothing that does not exist.** A date in the issue body and a report
that surfaces it when the date passes; the board model's `turn.py` already
carries the one recurrence this repository has, a post-deployment review falling
due after `REVIEW_DUE_DAYS`, so the shape is there to follow rather than invent.
Doing the review moves the date on, which is what makes it recur.

**Which one is dearer is not the one you would guess.** R2 is a few lines in the
board tooling and can be built at any time. R7 is blocked behind a project that
has not started.

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

**Answered, 2026-09-21: the engine benchmark only.** The dictionary benchmarks
cost about 6 s of CPU against the engine benchmark's 2.6 s, and the dictionary is
fixed at build time — it does not drift, so refreshing its timings every release
buys little for more than double the cost.

## R5's shape, and why it is not a small fix

**Load games on demand rather than at boot** is the obvious answer, and what it
costs is a cache policy, an eviction rule and a change to how the engine reaches
a game. Expiring `waiting` games is the cheap half and is worth doing whichever
way this goes, because it removes rows that no policy should ever have to hold.

**It is not gated on the state rework (#71)**, although it touches the same
structure. Owner, 2026-09-02: *"a game-related requirement outside #71 must be
independent of it and doable at any time."* R5 changes *when* a game is loaded,
not *what* a game is.

## R3 is a signal on somebody else's mechanism, like R7

R3 wants unusual growth noticed by something other than a bill or an outage,
starting with registrations. **That is monitoring and event management**, and
after 2026-09-21 it has an owner: #402, which holds the classification, the
counters, the alarms and what the server does about a failure.

**The split is the same one `docs/3.7` already makes for sweeps.** #402 owns the
mechanism — how a symptom becomes a number, how a number leaves the VM under
D49, how an alarm is built. Capacity Planning owns *this* signal: what counts as
unusual growth in registrations, and at what rate.

**And the dependency runs both ways, which is worth saying.** #402's thresholds
are meaningless without R1's table — *"registrations fail at N per minute"* is a
fact and *"N is forty times the ceiling"* is a plan. So R1 feeds #402, and #402's
mechanism carries R3.

**What R3 owes this project, then**, is a number and a rule rather than a build:
what rate of registration is unusual, measured against the six accounts and the
ceilings in the table above. That is answerable here and is not answerable
anywhere else.

## Where this leaves each requirement

| | state | owned by |
| --- | --- | --- |
| **R1** the capacity plan | **done** — the table above, measured on production 2026-09-21 | here |
| **R2** reviewed on a recurrence | designed: a due date in the issue body, surfaced by the board. Buildable now | here |
| **R3** unusual growth noticed | this project supplies the rate; #402 supplies the mechanism | split |
| **R4** where the service breaks | needs a harness. Measured against R1 | here |
| **R5** memory and startup stop growing | **RET-3, already decided.** Satisfied when #270 builds it | #270 |
| **R6** `Retry-After`'s margin | out of scope — see below | here, as a defect |
| **R7** benchmark timings refreshed | a due date now, a scheduled job once #400 ships | here |

**Three of the seven are not this project's to build**, which is the useful
result of the design rather than a disappointment: R5 was already decided, R7
needs a mechanism that does not exist, and R3 needs half of one being built next
door. What is left here is R1 (done), R2 (small), R4 (real work) and a rate for
R3.

## Four ideas from prior art, recorded and deliberately not built

Owner, 2026-09-22, having pointed at a 2012 capacity forecast he ran on a
telecoms integration platform: *"These are good ideas for the future, but do not
change anything now."* Written down because the cost of losing them is that they
get rediscovered badly in two years.

**Nothing from that work is reproduced here** — it is a client's and
proprietary. What follows is the method.

### 1. Two thresholds, not one: normal, and degraded

Their forecast carried a **normal running threshold** and a **single site
threshold** — what the platform could take when half the hardware was gone. The
second is the one that matters, because it is the one you meet on your worst
day, and a plan that only knows the first says you have headroom right up to the
moment you need it.

**Our analogue is one VM with no second site**, so the degraded case is not half
the hardware — it is a restart, a rebuild from backup, or running while a sweep
holds a lock. Whatever it turns out to be, the point stands: a single ceiling
describes a service that never has a bad day.

### 2. A threshold is a step function, not a constant

Theirs rose partway along the x axis, because a hardware upgrade was scheduled
and the chart showed the ceiling moving when the project landed. So the forecast
answered *do we breach before the upgrade arrives*, which is the actual question
and is invisible on a chart with a flat line.

**Ours are flat lines today** and would need to step the day the VM is resized.
`measurements.csv` carries the ceiling per period already, so the data model
supports this and only the chart does not.

### 3. Measure what the business drives, not what the OS reports

Theirs tracked **transactions per second** — peak hour and average, actual and
forecast — rather than CPU. Workload is what grows for a reason you can reason
about and forecast; CPU is a symptom of it, and forecasting a symptom means
forecasting the code as well as the demand.

**Our equivalent is moves, games started, registrations**, none of which the
capacity plan currently carries. It counts games *stored*, which is a stock, not
a rate.

### 4. Invert the model: express a resource ceiling in workload terms

The sharpest of the four, and the one that makes the other three pay. Their
derivation sheet records it as a method:

1. Take the resource threshold in resource terms — a CPU percentage.
2. **Measure the relationship at a known point**: at a recorded moment, peak
   workload and peak resource use were observed together, giving resource-use
   per unit of workload.
3. Invert it, so the threshold is restated **in transactions per second**.
4. Track and forecast the workload figure, because that is the one with a
   business meaning.

So the answer is not *"CPU reaches 70% in March"* but *"we run out at N
transactions per second, and we are at M"* — a number an owner can hold against
a growth expectation without knowing anything about servers.

**They recorded two derivations for one platform** and kept both: one from a
load test at installation, one from the measured relationship in production.
Two routes to the same ceiling disagreeing is itself information.

**What this would need here.** #91 is the load test — it produces step 2's
measurement. Until it exists there is no relationship to invert, which is why
this is recorded and not scheduled: the prerequisite is a requirement this
project already has and has not done.

## Load categories, and they already exist in the code

Owner, 2026-09-22: *"We should capture tps by load category, in our case not all
transactions are equal, but I suspect they will neatly fall into low (/health),
medium and high (auth, engine move)."*

**The suspicion is right, and it is better than a suspicion: the server already
classifies load, twice, and the two classifications do not agree.** Read
2026-09-22.

### What already bounds concurrency

`AppState` carries two semaphores, and their comments say exactly why each
exists and how it was sized for the production VM:

| | limit | why that number |
| --- | --- | --- |
| `hash_limit` | **4** | an Argon2 hash is about 19 MB and awaits nothing, so four is ~76 MB and keeps both cores busy. Unbounded on tokio's blocking pool would be 512 threads and no memory |
| `engine_limit` | **2** | a search is pure computation with nothing to overlap, so it matches the core count. Ten concurrent games meant ten blocking threads competing for two cores |

**Everything else is unbounded** and constrained only by the rate limiter.

### What already bounds rate

`throttle.rs` has three classes, which are *not* the same two:

| | per minute | burst |
| --- | --- | --- |
| auth | 10 | 10 |
| session | 240 | 60 |
| global | 1,200 | 200 |

### So the categories are four, not three

Putting the two together gives the boundaries the code actually enforces:

| category | what it is | bounded by | example |
| --- | --- | --- | --- |
| **trivial** | no auth, no database, no compute | nothing | `/health`, `/version.txt` |
| **ordinary** | session check plus a database query | session rate limit | the games list, invitations |
| **hash-bounded** | one Argon2 operation | `hash_limit` 4, auth rate limit 10/min | register, login, change password, reset |
| **engine-bounded** | a dictionary search | `engine_limit` 2 | a bot's move, a move preview |

**The last two are both "high" and they are not interchangeable**, which is the
part worth separating: one is memory-bound at four concurrent and the other is
CPU-bound at two. A single *high* category would average a memory ceiling
against a CPU ceiling and produce a number that describes neither.

**And `/health` is genuinely free**, which matters more than it sounds: the
external probe hits it every 60 seconds from three vantage points, so it is the
highest-rate endpoint the service has and contributes nothing to any ceiling. A
plan counting raw requests would be dominated by the one transaction that costs
nothing.

### What this changes, and it is nothing today

**The categories exist; what does not exist is a count per category.** Nothing
records how many of each kind arrive — the logs carry domain events, not
requests, and that is #402's gap rather than this project's. When #402's counters
land they should be keyed by these four, because the boundaries are already
enforced in the code and inventing a fifth classification for the plan would make
three that disagree instead of two.

**Recorded, not scheduled**, on the same grounds as the four ideas above: the
measurement that would give each category a cost is #91's, and it has not
happened.

## Out of scope, and why

**R6** — `Retry-After`'s margin — is a defect that happens to be capacity-shaped,
as the issue says. It needs no plan and no measurement: a chosen number replaces
one left over from rounding.

**The dictionary** is the largest single consumer of the server's 75 MB and it
does not grow: it is fixed at build time. It is a floor, not a slope.
