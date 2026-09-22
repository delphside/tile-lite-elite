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

## Who builds what

**Three work packages, raised 2026-09-22.** This document is the design for all
three; none of them re-derives it.

| | | |
| --- | --- | --- |
| **#403** | R1, R2, R7's interim due date | delivered |
| **#404** | R4 — measure where it breaks, by load category | the root of the chain; nothing blocks it |
| **#405** | R8, R9, R3's rate — derive the thresholds and the limits | blocked on #404, deliberately |

**#405 is where everything above this line is actioned.** It is blocked on
purpose: a model built before the measurement is a model fitted to guesses, which
is the failure this whole analysis exists to avoid. Its two owner inputs — the
utilisation threshold and the service level — do not wait on #404 and can be
settled at any time.

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

### 4a. What "measure the relationship" actually means: peak and average for a gauge, peak and total for a counter

Owner, 2026-09-22: *"for CPU utilisation, memory utilisation, and application
transactions we can capture peak and total values for different time
periods. We need to learn what drives the model."* Corrected the same day:
*"peak and average for utilisations, peak and total for application
counts/transactions."*

**Two kinds of thing, and each has its own honest summary.** CPU and memory
utilisation are read at an instant and move up and down — a **gauge**, in the
vocabulary Prometheus and OpenMetrics already standardised. A transaction is an
event that happens once and is counted — a **counter**. Averaging a counter
across a window is meaningless (an "average request" is not a thing); totalling
a gauge is meaningless (a "total CPU percentage" is not a thing). So:

| | kind | over a period, capture |
| --- | --- | --- |
| CPU utilisation, memory utilisation | gauge | **peak** and **average** |
| application transactions, by load category | counter | **peak** (a rate) and **total** (a count) |

**This is a generalisation of step 2 above, not a replacement for it.** The
prior art's method correlated one peak against one peak, at one recorded
moment. Capturing both statistics, at more than one period length, is what
*"learn what drives the model"* asks for: not one correlation point but enough
of them to see whether the relationship is real, and to notice when it is not.

**It already has a candidate case where it is not.** This project's own finding
(*What actually grows, and the one that is unbounded*, above) is that memory
growth is driven by an **accumulating stock** — games created and never
swept — not by a transaction **rate** at all. A rate-vs-rate correlation (peak
transactions against peak memory) would miss that relationship entirely; a
total-transactions-of-one-category-minus-total-of-another (creates minus
RET-3 sweeps) is closer to the actual driver. That is offered as a hypothesis
this measurement would test, not a conclusion — it has not been measured.

**What this asks of #404's schema.** `measurements.csv` today carries one value
per metric per period, which is enough for a resting sample and not enough for
a peak-and-average or peak-and-total pair. The schema question — additional
columns, or additional metric rows per statistic — is #404's to answer when it
is built; recorded here so it is not rediscovered as a surprise.

### 4b. A rough model, to be worked out properly by the capacity-planning practice

Owner, 2026-09-22, offering a sketch rather than a derivation:

> Roughly, this needs working out properly which is the job of the capacity
> planning practice: CPU requirement depends on peak CPU which depends on peak
> transaction rates per throttling interval; memory requirement is driven by
> auth transactions plus games in memory = games started per day / game
> duration (after we filter games held in memory); disk usage, for database
> and logs is driven by number of games not deleted, mean transactions per
> day * days history kept. This is just to give the general idea.

**Recorded as a sketch, not adopted as the answer.** What follows connects each
line to what is already measured or already named, and marks what is this
project's own inference rather than the owner's word.

**CPU: peak CPU ← peak transaction rate, per throttling interval.** This is the
interval work above, applied: each throttle class has its own characteristic
interval — the global bucket's 10s, session's 15s, auth's 60s, registration's
90s — and *"per throttling interval"* means the peak rate is read at the
interval the relevant bucket actually cares about, not at one interval for
everything. Weighted by #404's per-category cost (an Argon2 hash is not an
engine move), this is the workload side of step 3's inversion.

**Memory: auth transactions, plus games in memory by Little's Law.** Two
terms, and the second names a real theorem rather than an ad-hoc formula:
`games in memory = games started per day × mean time a game is held in
memory`, which is **Little's Law**, `L = λW` — the long-run number of items in
a system equals the arrival rate times the mean time each spends in it, with
no assumption about the distribution of either. `λ` is games started per day;
`W` is how long a game stays loaded before it is swept.

**"After we filter games held in memory" is the load-bearing clause.** `W` is
only a stable, meaningful number once RET-3 (#270) bounds the `waiting`
state — today seven of fifteen games have been in memory 46 to 62 days with no
sweep at all, so `W` measured now would be inflated by exactly the defect
this project already found and unbounded besides. The model needs #270 built
before `W` means anything.

**The auth term is the hashing semaphore's own memory**, already quantified
elsewhere in this document: up to `hash_limit` concurrent hashes at ~19 MB
each.

**Disk: games not deleted, plus mean transactions/day × days history kept.**
The second half is the journal's own shape already: `100 MB / 7 days` is
exactly *rate × retention window*. The first half is the terminal-games sweep
(a week after `ended_at`) and RET-3 together — the stock of games not yet
removed, which is Little's Law again, one level up: `L = λW` with `λ` = games
ending per day and `W` = the retention window before deletion.

**What this asks for.** #404 measures the inputs — costs per category, rates,
and (from *4a* above) enough peak/average and peak/total pairs to fit `λ` and
`W` rather than guess them. #405 is where the model is worked out properly and
turned into limits. **And it does not stop there**: refining it as real data
accumulates is the ongoing job, which is why *capacity-plan* is a row in
[docs/3.8](../../../../3.8-programme-activities.md) rather than a one-time
derivation — the sketch above is this month's starting point, not the answer the
practice on #407 exists to keep re-checking.

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

## Peak hour and spike, and the requirement is a spike *during* the peak hour

Owner, 2026-09-22: *"The model also measured peak hour and spike. The
requirement is to handle a spike during the peak hour."*

**Three figures, not one.** Their forecast plotted *average* and *peak hour*
separately, and the ceiling was tested against neither alone: the design case is
a spike arriving while the peak hour is already running. An average is what you
bill for; a peak hour is what you size for; a spike during the peak hour is what
breaks.

**Which composes with the degraded threshold.** The genuinely worst case is a
spike, during the peak hour, while degraded — and a plan that reports one
resting number is three steps away from that.

### The concepts already exist here, as the limiter's two numbers

Every rate class in `throttle.rs` is a **pair**, and the pair is exactly peak and
spike:

| class | per minute — the sustained rate | burst — the spike allowance |
| --- | --- | --- |
| register | 2 | 3 |
| auth | 10 | 10 |
| session | 240 | 60 |
| global | 1,200 | 200 |

**So the vocabulary is in the code and the capacity plan has never used it.**

### And that turns the requirement into a question with an answer

**A burst allowance is a permission, not a capability.** The limiter says what
we will *accept*; nothing says what we can *serve*. If the two disagree, the
limiter is not protecting anything — it is waving through a spike the service
then fails under, which is the failure mode it exists to prevent.

The costs to check it against are already measured:

| | cost | bound |
| --- | --- | --- |
| an Argon2 hash | **~47 ms** of CPU on a 2 vCPU box, recorded in `throttle.rs` | `hash_limit` 4 |
| an engine move | median **0.43 ms**, p99 **53 ms**, max **75 ms** on the rehearsal VM (`engine_timing_results.csv`, `1cac857`) | `engine_limit` 2 |

**The engine's tail is the surprise.** Its median is a hundredth of an Argon2
hash and its p99 is about the same as one. Sizing on the median would be sizing
for the case that never hurts.

**So the arithmetic the plan owes is roughly this**: a global burst of 200,
arriving during the peak minute, of which some fraction is hash-bounded at 47 ms
and some engine-bounded at up to 53 ms, served two cores at a time through
semaphores of 4 and 2. Whether that clears in a second or in ten is a number
nobody has worked out, and it is the first question the capacity plan should
answer once it can.

### The interval is a duration, not an averaging window

Owner, 2026-09-22: *"peak and spike are a function of the interval. The interval
will have meaning based on the queuing and throttling that happens."* And then,
correcting an earlier draft of this section: *"The comparison is not 200 per hour
or per second, it is between a rate of 200 per second for one second or for an
hour, or for a millisecond."*

**That is the right framing and the first one here was wrong.** Holding a *count*
fixed and varying the window is arithmetic — it only restates the rate. The
question that matters holds the **rate** fixed and varies **how long it is
sustained**: 200 per second for a millisecond is a fifth of a request, for a
second it is a burst, and for an hour it is 720,000 requests against a service
whose sustained limit is twenty a second.

**So *spike* is a rate with a duration**, and the capacity question is: at what
arrival rate, held for how long, does the service start refusing?

### Which is computable today, from the limiter alone

A token bucket of capacity `B` refilling at `r` per second, meeting arrivals at
`R` per second, drains in `B / (R − r)` seconds. Every one of those numbers is
already in `throttle.rs`, so the sustainable duration at each rate needs no
measurement at all:

| arrival rate | global | session | auth | registration |
| --- | --- | --- | --- | --- |
| 1/s | forever | forever | 12 s | 3.1 s |
| 5/s | forever | 60 s | 2.1 s | 0.6 s |
| 20/s | forever | 3.8 s | 0.5 s | 0.2 s |
| 50/s | 6.7 s | 1.3 s | 0.2 s | 0.06 s |
| 200/s | **1.1 s** | 0.3 s | 0.05 s | 0.02 s |
| 1000/s | 0.2 s | 0.06 s | 0.01 s | — |

*forever* means the arrival rate is at or below the refill rate, so the bucket
never empties.

**The headline: 200 a second is admitted for about one second and then
refused.** Not because anything measured the service — because that is what the
configuration says. The burst of 200 is a *one-second* allowance at that rate,
and calling it a spike allowance without saying for how long has been hiding
that.

### And the two halves of the question are different

**The limiter says what is admitted; the queues say what survives being
admitted.** Those are separate ceilings and only the first is known today:

| mechanism | constant | what it bounds |
| --- | --- | --- |
| `hash_limit` queue | `HASH_PERMIT_WAIT` = **250 ms** | how long a hash waits behind four others before 503 |
| `engine_limit` queue | `ENGINE_TURN_TIMEOUT` = **5 s** | a single search, with two running at once |
| the limiters | the table above | what is let through at all |

**So a rate held for less than 250 ms is invisible to everything**: it is latency
inside a queue and never a refusal. Between 250 ms and about a second, the
buckets absorb it. Past that, the sustained rate governs and the burst has
stopped helping.

**The plan therefore owes two curves, not one number**: the rate-against-duration
the *limiter* admits, which is above and derivable now, and the
rate-against-duration the *service* can actually serve, which needs #91. Where
the second is below the first, the limiter is admitting a spike the service
fails under — which is the thing R8 exists to catch.

### And registration is the outlier worth noticing

Its bucket holds three and refills one every thirty seconds, so **two
registrations a second is sustainable for a second and a half**, and anything
above that is refused almost at once. That is deliberate — a throwaway account is
how every other limit gets worked around. But it means a registration spike is
over before any reporting interval could see it, and registration is the flow a
capacity plan cares most about, because it is what grows the account table.

**Recorded, not built.** The limiter's curve is derivable now; nothing counts
arrivals at any interval at all, which is #402's gap.

### The limits are an output of this analysis, not an input to it

Owner, 2026-09-22: *"the throttling limits should come out of this analysis. They
are a mitigation that capacity planning uses to keep the utilisation within the
thresholds."*

**Which inverts everything above.** The sections before this treat `throttle.rs`
as given and derive a curve from it. That is backwards. The chain runs:

1. the hardware fixes a resource ceiling,
2. capacity planning sets the **utilisation threshold** under it — normal, and
   degraded,
3. the model converts that resource threshold into a **workload threshold**,
4. and the throttle limits are **chosen so that admitted load cannot exceed it**.

**A limit is a mitigation, and it is one of several.** More hardware, cheaper
code and a bigger semaphore are the others; throttling is the one that costs
nothing and works immediately, which is why it is reached for first and why its
numbers need a justification rather than a feel.

### Today only one of the four is a capacity control, and it is the unjustified one

Read 2026-09-22. Each limit's own comment says what it is for:

| limit | its stated basis | what kind of control |
| --- | --- | --- |
| registration 2/min, burst 3 | *"nobody legitimately registers twice in a minute"* | **abuse** — behavioural |
| auth 10/min, burst 10 | *"loose enough for somebody mistyping a password, tight enough that guessing is not worth attempting"* | **abuse** — behavioural |
| session 240/min, burst 60 | *"generous, because a person playing…"* | **fairness** — behavioural |
| global 1,200/min, burst 200 | *"a floor under the service as a whole… everybody together is asking for more than there is room for"* | **capacity** — and **no figure is given** |

**The three behavioural ones are correctly derived** and this analysis should
leave them alone: they answer *what would a real person do*, which is a question
about people and not about hardware. **The global one is the capacity control**,
it says so in its own comment, and 1,200 and 200 came from nowhere this document
can find.

### And the layers already disagree, which is provable without measuring anything

A global burst of 200 auth requests — plausible from 200 distinct addresses,
since each passes its own per-address limit with a full bucket — meets
`hash_limit`: **4 permits, ~47 ms per Argon2 operation, 250 ms of patience**,
on 2 cores.

| | served within the patience window | refused 503 |
| --- | --- | --- |
| if the 4 permits ran fully parallel | ~21 | ~179 |
| 4 permits contending for 2 cores | **~11** | **~189** |

**So the global limiter admits about twenty times what the next layer can
absorb.** Clearing all 200 as hashes would take about 4.7 seconds of wall time on
two cores, against a queue that waits 250 ms.

**That is not a bug** — the service refuses rather than falls over, which is what
both mechanisms are for. It is a *symptom of the limits never having been derived
together*: the burst of 200 protects nothing that `hash_limit` was not already
protecting, and the two were sized against different questions.

### What this asks for

**R9**: the throttle limits are derived from the capacity thresholds and the
derivation is recorded beside them, so a later reader can tell a number that was
computed from one that was chosen. The three behavioural limits keep their
behavioural justification, which is a legitimate derivation of a different kind —
what R9 forbids is a capacity limit with no capacity behind it.

**It cannot be answered yet**, and the ordering is the point: step 3 needs the
workload-to-resource model, which needs #91's measurement. Until then the global
burst is a guess, and the honest thing is that it is written down as one.

### What this adds

**R8**, on the issue: *the service handles a spike during the peak hour, not
merely the average*. Stated as a requirement rather than folded into R1, because
R1 asks what is consumed and this asks what happens at the worst realistic
moment — different questions with different evidence.

**Still not built**, for the same reason as the rest: the measurement lives in
the stress-testing requirement, #91.

## Two more from the prior art: annotation, and seasonality

Owner, 2026-09-22.

### The chart explains its own anomalies

> *"the forecast is presented clearly so everything can be easily seen in one
> chart, with bubble text noting key events (an outage and a new product
> launch)."*

**A spike with no note beside it is read twice**: once as a defect, and once more
by the next person. Theirs carried callouts naming what happened — an outage, a
launch — so a reader could tell a number that means *something broke* from one
that means *the business grew*, without asking anybody.

**It also protects the regression.** A launch is a step change and an outage is a
hole; a straight line fitted through either without acknowledgement produces a
trend that is an artefact of one event. Annotating is the cheap half of that;
deciding whether the point belongs in the fit at all is the other half, and is a
judgement a note makes visible.

**What it would need here:** an `events.csv` beside `measurements.csv` — a
period, a label, and whether the point is excluded from the fit. The generator
already has the x-position; a callout is a line and a text element.

### The baseline carries seasonality, at three scales

> *"the baseline forecast includes a seasonal pattern, there is a christmas bump.
> there is also a weekly pattern and a daily pattern."*

**Three cycles, and a straight line sees none of them.** Annual (a Christmas
bump), weekly, and daily. A regression over twelve monthly points fitted through
an annual cycle will read the cycle as trend, and will do it most confidently
exactly where the series is longest.

**And this connects back to the interval, sharply.** Their monitoring column read
*"Peak Message TPS by Month"* — a **monthly series of a peak figure**, not a
monthly average. That is how a monthly report can size for a daily peak: you
report monthly, but what you report is the peak the day contained.

### Which is a criticism of the report already written

**September's figures are single instantaneous readings.** Memory, disk, journal
and load were read once, on 2026-09-21, from a service nobody was using. They are
neither averages nor peaks — they are one sample, and the report says as much
under *what is not known*, but the table presents them as though they were the
month's figure.

**So `measurements.csv` needs a shape it does not have**: per period, the
average *and* the peak, with the peak's interval stated. Until then the plan is
sizing on a resting number, which is the mistake R8 exists to name one level up.

**Recorded, not built**, like the rest — but this one is the cheapest of them and
does not wait on #91. Capturing a peak needs something sampling more often than
monthly, which is #402's counters again.

## Why an hour, and there are two intervals not one

Owner, 2026-09-22: *"We took peak hour values because there is no pattern within
an hour, and it is long enough to have a consistent rate."*

**That is a criterion, and this document had been treating the hour as a
convention.** The hour was chosen because it sits between two failures:

| too short | too long |
| --- | --- |
| not enough transactions for the rate to be stable — you measure noise and call it a peak | you average across a pattern and the peak disappears into it |

**The peak interval is therefore the shortest window over which the rate is both
flat and stable.** Flat, because a window containing a pattern reports its
average and hides its peak. Stable, because a rate computed from too few events
is an artefact of arrival timing.

### Which corrects a conflation earlier in this document

The section on queueing constants concluded that the interval comes from
`HASH_PERMIT_WAIT` and the buckets' refill times. **That is right for one
interval and wrong for the other**, and they are different figures answering
different questions:

| figure | interval comes from | for this service |
| --- | --- | --- |
| the **peak rate** you size against | the workload's own statistics — the window where the rate is flat and stable | unknown; see below |
| the **spike duration** you must survive | the service's queues and buckets — what it can absorb before refusing | 250 ms to ~10 s, derived above |

**Both are needed and neither substitutes for the other.** A peak rate with no
duration cannot be tested against a bucket; a spike duration with no underlying
rate is a window with nothing in it.

### And at our volume the hour fails the second test badly

**Six accounts and fifteen games in about two months.** An hour of this service
contains, typically, nothing at all — so an hourly rate is zero almost always and
enormous occasionally, which is the definition of a window too short to have a
consistent rate.

**So the hour does not transfer; the criterion does.** Ours would have to be much
longer today — a day or a week — and it **shrinks as volume grows**, which is
worth writing down because it means the interval is not a constant to be chosen
once. A capacity plan that fixes its interval at the start reports a stable rate
early and a smoothed-away peak later, and nothing signals the change.

**The practical consequence for the next report:** state the interval beside the
peak, always, and re-derive it rather than inheriting it. The first time an hour
contains a consistent rate is itself a finding worth reporting — it is the point
at which this service starts having a peak hour at all.

## The within-hour distribution is random, so the spike is calculated, not measured

Owner, 2026-09-22, sharpening the previous section: *"It is more accurate to say
that the distribution of transactions within an hour is consistent with a random
distribution, given that total count for the hour. So normal statistics can be
used to predict the peak for any particular interval."*

**That is a much stronger claim than *no pattern*, and it collapses the
measurement problem.** If arrivals within the hour are Poisson conditional on the
hour's total, then the peak in *any* shorter window follows from the hourly count
alone. Nothing has to be sampled at second granularity — you measure at the
interval where the rate is stationary, and derive everything below it.

**Which makes *peak* and *spike* one measurement and one calculation**, where
this document had been treating them as two measurements.

### What it gives, at a level exceeded about once an hour

| arrivals/hour | mean/s | peak in 1 s | peak in 10 s |
| --- | --- | --- | --- |
| 600 | 0.17 | 3 | 6 |
| 3,600 | 1 | 6 | 20 |
| 36,000 | 10 | 23 | 129 |
| 72,000 | 20 | 37 | 240 |

**The last row is this service at exactly the global limiter's sustained rate**
of 1,200 a minute.

### And the naive comparison against the bucket is wrong

240 in ten seconds against a burst of 200 looks like a shortfall. **It is not**,
and the error is worth recording because it is easy to repeat: a token bucket is
not a counter over a window. It refills continuously, so what matters is the
largest *excursion above the refill line*, not the raw count in an interval.

Simulated — Poisson arrivals into the real bucket, capacity 200 refilling at 20 a
second, an hour at a time:

| load, as a fraction of the sustained rate | organic refusals per hour |
| --- | --- |
| 50% | 0 |
| 80% | 0 |
| 90% | 0 |
| 95% | **0** |
| 100% | **~95** |

**So the burst of 200 is comfortable up to about 95% of the sustained rate**, and
falls apart only at 100% — where it must, because the drift is zero and a
zero-drift random walk drains any finite bucket given time.

### Which narrows R9 rather than answering it

**The burst is defensible.** 200 absorbs organic Poisson variation at every load
short of saturation, and that is now a derivation rather than a feel. If it were
halved to 100 the same simulation would say whether that still holds — which is
the point: the number is now checkable.

**The sustained rate is the one still unjustified.** 1,200 a minute is the figure
that should come out of the utilisation threshold via the workload model, and
nothing derives it. That is the narrower thing R9 now asks for.

### So peak and spike are different kinds of thing, and only one is a measurement

Owner, 2026-09-22: *"if we define peak to mean the modelable peak using Poisson,
and spike to mean something unexpected due to an event, then spike cannot be
measured and becomes an allowance."*

**These are the definitions this document uses from here.**

| | what it is | where the number comes from |
| --- | --- | --- |
| **peak** | the modellable maximum of organic arrivals | **derived** from the hourly count and the window, by the calculation above |
| **spike** | something unexpected, caused by an event | **allowed for**. It cannot be derived, because the event that causes it has not happened |

**A spike is a policy, not a finding.** Deciding to hold 30% headroom above the
modelled peak is a decision about how much to pay for surviving the unforeseen,
and it belongs to whoever is paying. What the analysis owes is the peak, stated
honestly, so the allowance is added to a number rather than to a guess.

**And it explains the shape of the prior art.** A launch and an outage were
annotated on their chart precisely because they are the events a distribution
cannot produce; the annotation is what keeps them out of the trend, and the
allowance is what survives them.

### The peak rises with how long you watch, and that is the other input

Owner, same day: *"the other factor in the model is the number of hours we are
considering, if it runs for long enough then unusual grouping will occur
eventually."*

**So the peak is not one number — it is a number and a period.** *Once an hour*
and *once a year* are different peaks from the same distribution:

| arrivals/hour | mean per 10 s | once an hour | once a day | once a month | once a year |
| --- | --- | --- | --- | --- | --- |
| 3,600 | 10 | 20 | 24 | 27 | 29 |
| 36,000 | 100 | 129 | 139 | 148 | 154 |
| 72,000 | 200 | **240** | 254 | 266 | **274** |

**The growth is slow, and that is the useful part.** From once an hour to once a
year is a factor of 8,760 in exposure and about 14% in the peak. A capacity plan
can therefore quote a once-a-year peak almost for free, rather than sizing to an
hourly figure and being surprised annually.

**Which also means a service level is an input.** *How often are we willing to
refuse organic traffic* picks the column, and nothing else does. That question is
the owner's, and it is the second thing R9 needs after the utilisation threshold.

### And the simulation had to be re-run over a longer period

The bucket simulation above ran for an hour, which is exactly the mistake this
section names. Re-run:

| load, fraction of sustained rate | 1 hour | 1 day | 1 month |
| --- | --- | --- | --- |
| 80% | 0 | 0 | 0 |
| 90% | 0 | 0 | 0 |
| 95% | 0 | 0 | **0** |
| 98% | 0 | 0 | **182** |

**The conclusion survives and gets a boundary**: the burst of 200 holds to about
95% of the sustained rate over a month, not merely over an hour, and gives way
between 95% and 98%. A one-hour simulation could not have told the two apart, and
would have reported 98% as safe.

### The assumption is load-bearing and names its own exceptions

**Poisson requires independent arrivals**, and the interesting failures are
exactly where independence breaks: a bot harness (#10) driving many games at
once, a retry storm after an outage, an emailed invitation batch landing
together. Those are *correlated* arrivals, the model does not cover them, and
they are the cases a capacity plan most wants to survive.

**So the calculation gives the organic peak**, and correlated events remain a
separate question — one that a spike test constructs deliberately rather than
infers from a distribution.

## Out of scope, and why

**R6** — `Retry-After`'s margin — is a defect that happens to be capacity-shaped,
as the issue says. It needs no plan and no measurement: a chosen number replaces
one left over from rounding.

**The dictionary** is the largest single consumer of the server's 75 MB and it
does not grow: it is fixed at build time. It is a floor, not a slope.
