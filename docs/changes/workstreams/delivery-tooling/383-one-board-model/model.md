<!-- markdownlint-disable-file MD013 -->
# The model: what it holds, who asks it, and why nothing is computed twice

For #383. Owner, 2026-09-17: *"python for the model so it can be structured to support each use case."*

This document designs the model. It does **not** restate the process. Three documents are the description and this is what falls out of them:

| | |
| --- | --- |
| [`flows.md`](flows.md) | the change flows, and the gates in each |
| [`obligations.md`](obligations.md) | what each issue type owes at each lifecycle step |
| [`reports.md`](reports.md) | the reports, each from its purpose to its content |

The order matters and is the owner's: **describe the process and the reports, list their checks, gates, actions and decisions, and only then say what information the model must hold.** Designing the model first produces a data structure convenient to build and awkward to ask.

**Nothing here is derived from the scripts that exist today.** An earlier draft organised itself around the nine consumers, which reads as a rewrite of what is already there and quietly adopts today's implementation as the specification — including its defects, since three of those scripts answer the same question differently. The scripts appear once, at the end, as a migration note. Two of the seven reports do not exist today at all, which is the clearest sign that deriving from them was the right way round.

## The one rule

> **A fact is derived in exactly one place, is named there, and every consumer imports it.**

Everything below is machinery for that sentence. Nine consumers today each re-derive the same few concepts from raw GitHub payloads, and the observed cost is not duplication but **disagreement**: two copies of "is this built" disagreed about parentage (#370, #375), and two pictures of "does this owe a route" disagreed about parents (#297, this sweep). Duplication is cheap; disagreement is what ships a wrong answer.

## The four layers

Each layer may call the one below it and never the one above.

| layer | module | may do | must not |
| --- | --- | --- | --- |
| **sources** | `board/sources/` | talk to GitHub, git, HTTP | interpret anything |
| **snapshot** | `board/snapshot.py` | fetch once, record freshness and failures | derive facts |
| **model** | `board/model.py` | define issues and every derived fact | perform I/O |
| **obligations** | `board/obligations.py` | hold the grid, evaluate predicates | reformat for a reader |
| **commands** | `board/commands.py` | write what a rule implies, straight through to GitHub | hold a record of its own |
| **consumers** | reports and gates | ask, format, decide what to do about the answer | compute anything |

The layer boundary that does the work is the third: **no consumer computes.** A consumer that needs to know whether an issue is a parent asks; it does not look at sub-issues.

## `is_parent`, end to end

The owner's example, and the one that has broken twice.

**1 · The process says it.** Two obligations in `obligations.md` name it: *a parent must not be at Development, User testing or Deployment*, and *a parent owes no route* — its work packages carry one each.

**2 · So a distinction is needed**, and it has exactly one definition — as a class rather than a predicate, which is why `classify` below is the only place parentage is decided:

```python
# board/model.py
@property
def is_parent(self) -> bool:
    """A project whose sub-issues include projects.

    NOT "has sub-issues". A project carries folded requirements as sub-issues
    routinely and is still one delivery owing one route: #214 has two work
    packages and two folded requirements. Counting sub-issues rather than
    project sub-issues misread it, which is the defect behind #297.
    """
    return self.type is IssueType.PROJECT and any(
        sub.type is IssueType.PROJECT for sub in self.sub_issues
    )
```

**3 · Everything that branches on it imports it.** Today these are four separate implementations, two of which disagreed:

| consumer | what it does with it | today |
| --- | --- | --- |
| `check-transitions.sh` | a parent at Development is refused | its own jq |
| `status.sh` | a parent is not asked for a route | fixed 2026-09-17, its own jq |
| `deploy.sh` | settling skips the parent, settles its packages | its own query |
| `verify.sh` | commits naming a parent are kept apart from its packages | its own grep, #375 |

**4 · The test moves with the definition.** `scripts/tests/status-parent-route.test.sh` already extracts the function from the script rather than copying it. Under the model there is one function, so there is one test, and it covers every consumer at once. That is the saving — not fewer lines, but a defect that can only exist in one place.

## An issue type is a class

Owner, 2026-09-17: *"In the python we should model each issue type."*

GitHub gives three types. The lifecycle gives a fourth distinction inside one of them, because a `Project` is one of three different things with three different obligation sets.

```text
Issue                     what every issue has; step is abstract
├── Requirement           step = Stage
├── Project               step = Phase
│   ├── ParentProject     owns requirements and design; no route, no milestone
│   ├── WorkPackage       one delivery; carries route and milestone
│   └── StandaloneProject one delivery, no children; carries both
├── Decision              step = Decision State
└── PullRequest           step = PR State
```

**A pull request is an issue.** Owner, 2026-09-18: *"Pull Request is a particular type of issue in GitHub."* GitHub models it that way and so should we — it has a number, a body, a state, comments and reviewers, and the board already carries a `PR State` field for it. Leaving it out would put the review surface outside the model while every other artefact is inside, which is how `sync-pr-state.sh` came to hold its own picture of the board.

Its step is the `PR State` that `sync-pr-state.sh` derives today: `Drafting`, `Awaiting review`, `Approved`, `Changes requested`, and merged. That derivation belongs in the model with the rest.

**`is_parent` stops being a predicate and becomes a class.** A factory reads the GitHub type and, for a project, its sub-issue shape:

```python
def classify(raw: RawIssue) -> Issue:
    match raw.issue_type:
        case "Decision":    return Decision(raw)
        case "Project":
            # A project whose sub-issues include projects is a parent. NOT
            # "has sub-issues": a project carries folded requirements as
            # sub-issues routinely and is still one delivery owing one route.
            # #214 has two work packages and two folded requirements, and
            # counting sub-issues rather than project sub-issues misread it,
            # which is the defect behind #297.
            if any(sub.issue_type == "Project" for sub in raw.sub_issues):
                return ParentProject(raw)
            return WorkPackage(raw) if raw.parent else StandaloneProject(raw)
        case "Requirement": return Requirement(raw)
        case None:
            # Owner, 2026-09-18: untyped becomes a Requirement. There is no
            # Untyped class - a class owing nothing is skipped by every rule
            # keyed on type, which is #361 restated rather than fixed.
            return Requirement(raw, type_was_defaulted=True)
```

That is the whole of the definition, in one function, and a class is better than a predicate for three reasons:

| | |
| --- | --- |
| the obligations attach to the class | `ParentProject.owes(step)` rather than a grid lookup guarded by an `if` |
| impossible states stop being expressible | `ParentProject.route` does not exist, so no consumer can ask for it |
| the defect has one home | `classify` is where parentage is decided, and one test covers every consumer |

### Two defaults, both flagged

Owner, 2026-09-18: *"Untyped should be changed to Requirement. Requirements with unset state are set to Triage."*

| unset | becomes | flag |
| --- | --- | --- |
| issue type | `Requirement` | `type_was_defaulted` |
| a requirement's `Stage` | `Triage` | `stage_was_defaulted` |

**Defaulting and reporting are not alternatives; the design needs both, for different reasons.** Defaulting stops an issue falling outside every rule, which is what made twenty of them invisible under #361. The flag stops the default becoming the quiet answer: R4 reports a defaulted field, because an issue raised outside the three templates is worth knowing about even once it has been made workable.

**A default that is not reported is how a board drifts while every report stays green.**

**Applied in both places, deliberately:**

| | |
| --- | --- |
| **on read**, in `classify` | no report breaks and no rule is skipped, the moment such an issue appears |
| **on write**, via `board fix defaults` | the board becomes correct, so GitHub and the model agree |

Reading alone leaves blank fields that only the model interprets — two pictures again, which is what this design exists to remove. Writing alone leaves the gap between raising and fixing as a hole in every report.

**Measured 2026-09-18: zero untyped open issues, and zero of the sixteen open requirements with `Stage` unset.** Both defaults are prevention, and `board fix defaults` currently has nothing to do. Two routes keep it necessary: a blank issue from the GitHub UI, which no `config.yml` disables, and the API, which requires no type. All three templates set one correctly.

### What each class knows

```python
class Issue:
    number: int
    title: str
    state: str
    fields: Mapping[str, str]      # by NAME, never by option id
    labels: frozenset[str]
    @property
    def step(self) -> str: ...     # Stage | Phase | Decision State
    @property
    def owes(self) -> tuple[Obligation, ...]: ...
    @property
    def waiting_on(self) -> Actor | None: ...
```

and the facts that only some classes have, which is the point of having classes:

| | on | why |
| --- | --- | --- |
| `route`, `milestone` | `WorkPackage`, `StandaloneProject` | a delivery has both; a parent has neither |
| `deliveries` | `ParentProject` | what it delivers, and through which packages |
| `commits_naming_it`, `commits_naming_its_parent` | `WorkPackage` | kept apart — #375 |
| `agreed`, `open_actions` | `Decision` | the body headings `check-transitions` reads |
| `review_decision`, `is_draft`, `reviewers` | `PullRequest` | the `PR State` derivation, which lives here rather than in a script |
| `requests`, `leaves_out` | `PullRequest` | the two headings the review surface owes |
| `is_built`, `is_closable` | `WorkPackage`, `StandaloneProject` | one implementation each; three scripts ask each today |
| `body` | all, **fetched on demand** | 2.7s of the 4.6s fetch, and only R4 and the decision checks need it |

**Fields are resolved by name at the boundary.** Option ids live in `sources/github.py` and nowhere else. Five scripts carry ids like `IFSS_kgDOAsQ80g` today, which is a fact about the GitHub instance leaking into process logic.

## What a fetch costs, measured

Owner, 2026-09-17: *"We should understand the time to fetch data."* Measured on 2026-09-17, 45 open issues and 272 closed.

| what | time | note |
| --- | --- | --- |
| **the whole open board, one GraphQL query** | **4.6s** | 300KB, every field a snapshot needs |
| the same without issue bodies | 1.9s | 23KB — **bodies are 2.7s and 92% of the payload** |
| 100 most recent closed issues | 1.3s | |
| one issue, `gh issue view` or GraphQL | 0.6s | what the scripts do today, per issue |
| `git fetch origin` | 1.5s | |
| `git log --grep` over the release range | 0.03s | local, effectively free |
| `git ls-remote origin main` | 1.4s | |
| production `/health` | 0.2s | |

And what the consumers cost today, end to end:

| | today | why |
| --- | --- | --- |
| `status.sh` | **46.0s** | ~25 per-issue queries at 0.6s, plus health, plus git |
| `actions.py` | 10.3s | |
| `inbox.sh` | 0.6s | one query already |

**The snapshot is cheaper than what a single consumer does today.** `status.sh` takes forty-six seconds to build a picture that one query builds in under five. That is the measurement that matters, and it changes the design:

> **The cache is an optimisation for cheap readers. It is never a correctness dependency for anything that decides.**

Every gate and every check can simply fetch. At 4.6s a deploy that refreshes before each of its eight gates would pay 37s, which is why they share one refresh — but even the naive version is affordable, so no gate need ever reason about staleness. That removes most of the risk the owner's caution is about: the consumers where a stale answer would do damage are exactly the ones that never read a cache.

**Bodies are the expensive half and not everyone needs them.** The obligations grid reads body headings, so `check-transitions.sh` needs them; `status.sh` and `actions.py` do not. The snapshot therefore fetches bodies on demand rather than always — 1.9s against 4.6s for the consumers that can skip them.

## Consistency, which is where caches go wrong

Owner, 2026-09-17: *"Data must be consistent with itself and other sources, and any writes."* Three separate problems, and they need three separate answers.

### Self-consistency: a snapshot is a window, not an instant

GitHub offers no transactional read, so a paginated fetch can see the board change underneath it. Today 45 open issues fit in one page of 100, so the open board **is** an instant — but that is a fact about the current size, not a property of the design, and it stops being true at 100.

| | |
| --- | --- |
| open issues | one page today; the snapshot records `pages=1` and is an instant |
| closed issues | 272, three pages, and therefore a window |
| the rule | a snapshot records `started_at`, `finished_at` and `pages`; a window wider than one page is reported, not hidden |
| the hard rule | **a consumer is handed one snapshot and every fact comes from it.** Two snapshots are never mixed in one answer |

### Consistency with other sources: git is a different clock

`commits_naming_it` comes from git; the issue comes from GitHub. `git log --grep` is free precisely because it reads whatever `origin/main` happens to be locally, which may be hours old. A `built` answer computed from a stale `origin/main` and a fresh GitHub is wrong in the most dangerous direction: it reports work as unbuilt that is built, or misses a commit that closes a gate.

| | |
| --- | --- |
| the snapshot records | the `origin/main` sha it read, and whether it fetched |
| `REFRESH` implies | `git fetch` first — the 1.5s is part of the price of deciding |
| a report may skip the fetch | and says which sha it used, so a surprising answer is traceable |

The same applies to `/health`: it is a live reading, and pairing a live version with a stale board is how *"production is 52 changes behind"* could be computed from the wrong `main`.

### Consistency with writes: a write invalidates everything

A process that mutates the board must not then serve its own stale reads. The rule is the blunt one, and it is affordable only because a refetch is 4.6s:

> **Any write through the model invalidates the whole snapshot cache, for every consumer, immediately.**

Not a targeted invalidation of the issue written — a write changes derived facts on other issues, and working out which is exactly the reasoning that gets caches wrong. `AFTER_WRITE` then re-reads from source, and the next reader pays a fresh fetch it would mostly have paid anyway.

`deploy.sh` settling is the case that matters: it writes phases and milestones on several issues, and every later gate and report must see them.

## Latency is declared per consumption, and some consumptions refresh

Owner, 2026-09-16: *"Different points in the process need different latencies. A to do list differs from a production deployment gate."* And 2026-09-17: *"some checks should refresh the cache. So the latency requirement is something to be documented for each consumption."*

So latency is not a convention the caller remembers — it is **an attribute of the consumption, written down beside it**, in the same way `Route` is an attribute of an artefact. Four values, and the third is the one that was missing:

| freshness | means | who asks for it |
| --- | --- | --- |
| `CACHED` | whatever is there; the answer carries its age | reports, where a stale row is visible and harmless |
| `RECENT(n)` | cached if younger than `n`, else fetch | sweeps that run often and need not pay every time |
| `REFRESH` | fetch now, **and write the result to the cache** | anything that decides: every gate, and any check whose answer stops work |
| `AFTER_WRITE` | re-read following a mutation, ignoring the cache entirely | `settle`, where the point is to confirm what was just written |

**`REFRESH` fetches the board and `git fetch`es, and updates the cache.** At 4.6s plus 1.5s it is affordable for anything that decides.

**`REFRESH` updates the cache rather than bypassing it.** That is the change, and it is what makes the cache worth having: a gate that must fetch leaves the board fresher for every report behind it, instead of paying for a fetch and throwing it away. A deploy refreshes on its first gate, and the seven after it read a snapshot seconds old.

`AFTER_WRITE` is separate because it must **not** be served by the cache at any age, including one written moments earlier by the mutation's own optimistic update.

### The consumption register

Every consumption declares its latency. The rows are the reports of [`reports.md`](reports.md) and the gates of [`flows.md`](flows.md) — not the scripts, which are an implementation of them and may not survive.

| consumption | freshness | because |
| --- | --- | --- |
| **R5** deployment gates | `REFRESH` on the first gate, `RECENT(60)` for the seven after | eight gates in one run; the first pays for all of them |
| **R5** *settle* | `AFTER_WRITE` | it confirms the write it just made |
| **R6** post-deployment | `REFRESH` | it answers whether the deploy worked; a stale yes is the failure it exists to catch |
| **R4** issue completeness | `REFRESH` | it reads bodies, and is the slowest fetch; worth being right |
| obligation checks at a transition | `REFRESH` | they refuse — the answer stops work |
| **R1** what needs the owner | `RECENT(300)` | a to-do list, in the owner's own words |
| **R3** where the programme stands | `RECENT(300)` | a five-minute-old board is a correct board for reading |
| **R2** what changed since I looked | `RECENT(300)` | a conversation does not turn over in minutes |
| **R7** model-versus-scripts diff | `REFRESH` | comparing two pictures requires one moment |
| the per-turn sweep | `CACHED` | runs constantly, must cost nothing, and reports rather than refuses |

Two things fall out of reading it as a table. **Every consumption that refuses asks for `REFRESH`, and every consumption that reports does not** — the gate-and-check distinction turning up again, as a cache policy. And the per-turn sweep is the only `CACHED` consumption running unattended, which is exactly why it must never gate.

## Everything uses the model

Owner, 2026-09-17: *"We want everything to use the new model."*

No consumer is exempt, including `inbox.sh`. An earlier draft of this document carved it out because it reads comment threads and the obligations grid deliberately does not. That conflated two different things:

| | |
| --- | --- |
| **the model** holds comments | it is a source like any other, and `inbox.sh` needs it |
| **the obligations grid** ignores comments | evidence and conclusions live in the body — owner, 2026-09-16 |

So `sources/github.py` fetches comments, `Issue.comments` exists, `inbox.sh` asks for it, and **no obligation predicate may read it**. That is a rule the grid can enforce on itself rather than a carve-out in prose: an obligation whose predicate touches `comments` is rejected at import.

Nine consumers, nine users of the model, one picture.

## The grid is the requirement, not a description of it

`obligations.md` left this open. It should be the requirement.

```python
# board/obligations.py
OBLIGATIONS = (
    Obligation(
        id="parent-not-building",
        applies_to=IssueType.PROJECT,
        when=lambda i: i.is_parent and i.phase in BUILD_PHASES,
        holds=lambda i: False,
        because="oversight is a design role; the work packages build",
        status=Status.NOW,
    ),
    ...
)
```

One table, 28 rows, matching `obligations.md` line for line. `check-transitions.sh` is then **generated from it** rather than agreeing with it by hand, and the 16 rows currently marked `gap` become reports by flipping a status, not by writing 16 checks.

This also fixes the failure mode this sweep found. The grid said a parent owes a route at `Scope` — wrong, and it was the single written statement of what is owed. Had the model been generated from it, the defect would have been generated too. A grid that is executable is a grid whose rows get tested.

## Avoiding replicated logic: the rules that enforce it

1. **No consumer writes GraphQL.** `sources/github.py` is the only call site. Measurable: `grep -c 'gh api graphql' scripts/` outside `board/` should reach 0.
2. **No consumer resolves a field.** Names in, names out.
3. **A predicate is imported, never re-expressed.** If a consumer needs *almost* `is_parent`, that is a second named fact with its own reason, not an inline variation.
4. **Two facts that look alike are distinguished in code, not in a comment.** `commits_naming_it` and `commits_naming_its_parent` are separate properties because conflating them caused #375.
5. **Every derived fact carries the issue number that made it necessary**, as `is_parent` does above. A fact nobody can attribute is a fact nobody can delete, and deleting is in scope.

## Writing through the model

Owner, 2026-09-17: *"Do we want to update via the python? Let's take the opportunity that using a high level language gives us to build a mini app in so far as that is useful. It should operate a bit like the cli admin tool, but being careful not to go too far and start duplicating GitHub and git."*

Yes, with one test that decides every case:

> **The app writes what a rule implies. It does not write what a person would rather type into GitHub.**

A write earns its place when the value is *derived* — when doing it by hand means applying a rule from memory, which is where the board's data defects have come from. It does not earn its place merely because it is possible.

| write | why it qualifies |
| --- | --- |
| settle after a deploy | phases, milestones and comments across several issues, all derived from what shipped |
| correct a field the rules determine | clearing a route on a parent is the rule applied; doing it by hand is the rule remembered. Two parents had one set, and the report had been changed to stop complaining |
| advance a step, obligations checked first | the check and the transition in one act, so a step cannot advance while incomplete |
| raise an issue with its fields set | the minimum from `obligations.md` at Triage, rather than a form somebody completes later |
| close, with the closedown obligations answered | the row most often skipped, because by then the interest has moved on |

| refused | because |
| --- | --- |
| editing a body | GitHub's editor is better, and a body is prose |
| branches, pull requests, merges | `git` and `gh` do this, and doing it twice is how two tools disagree |
| browsing, searching, listing for their own sake | the GitHub UI exists and is better |
| anything the owner would want to see happen | the job spec already says so |

**The shape is a small command set over the model**, not an admin console:

```bash
board show 383              # one issue: type, step, what it owes, what is missing
board check 383             # R4 for one issue
board check --all           # R4 for the board
board settle 0.8.1          # the deploy's write step
board fix route --dry-run   # data the rules determine, listed before it is changed
```

**`--dry-run` is the default for anything that writes more than one issue.** The route correction is the worked example: it touched two issues, and listing them first is the difference between a fix and a surprise.

**The line not to cross** is the one the owner drew. A model that can write is a model that can drift from GitHub, and the guard is that every write goes straight through to GitHub and the snapshot is invalidated — no local state of record, no queue, no reconciliation. The app is a way of applying rules to the board, not a second copy of it.

## What exists today, and what becomes of it

A migration note, not a specification. The nine scripts are one implementation of the seven reports and the gates; they are listed here so the move can be planned, not because the design is derived from them.

| today | serves | after |
| --- | --- | --- |
| `deploy.sh` | R5 | gates call the model; the deployment mechanics stay in bash |
| `verify.sh` | R6 | asks the model |
| `check-transitions.sh` | obligation checks | generated from the grid |
| ~~`status.sh`~~ | R3 | **retired 2026-09-19.** `board-status.py` replaces it. Three sources meet there — GitHub for what a change is, git for where it got to, `/health` for what is running |
| `actions.py` | R1 | asks. `board-actions.py` runs beside it: R1 as specified is narrower — only what the owner must do — so a difference between them is the expected result, not a defect |
| `inbox.sh` | R2 | asks, including comments |
| `sync-pr-state.sh` | a write | `board` command |
| `turn-check.sh` | the sweep | asks, `CACHED` |
| `roadmap-diagram.py` | **R8** | asks the model. Reformatted: it drew structure, and R8 wants sequence |
| — | **R4** | **new** |
| — | ~~**R7**~~ | **retired 2026-09-19** with `status.sh`, having done its job: five disagreements, the model right about all five |

`roadmap-diagram.py` was listed here with no report against it, and read as a candidate for deletion. That was wrong, and wrong in an instructive way: the report list was incomplete, not the script redundant. Owner, 2026-09-18: *"roadmap-diagram.py has a purpose but the format should be updated."*

What it was missing was a **purpose stated independently of what it drew**. Asked for one, the answer is R8: dependencies are recorded on issues and no board view can show them, so something has to draw them. The script satisfied that need in the wrong format — it drew *structure*, what belongs to what, when what is wanted is *sequence*, what comes before what. Deriving from purpose caught that the format was wrong; it very nearly also concluded the script was, because a report missing from the list looks exactly like a script with no reason to exist.

## Parallel running, to catch what changes unexpectedly

Owner, 2026-09-17: *"We can have some parallel running to see if we change something unexpected."*

The point is **not** a staged rollout where some consumers stay behind. Everything moves to the model. Parallel running is the safety net across the move, and it answers one question: **does any consumer now say something different from what it said yesterday?**

So each converted consumer runs both ways for a period and reports only where they disagree:

| the diff says | what it means | what to do |
| --- | --- | --- |
| nothing | the model reproduces the old behaviour | convert the next one |
| a difference the model is **right** about | an old bug, now visible — #297 was exactly this | record it and keep the model's answer |
| a difference the model is **wrong** about | a defect in a derived fact, caught before it gated anything | fix the model |

The second row is the one to expect, and it is why the diff is worth running rather than merely reassuring. Two of the disagreements this design exists to remove — parentage in `built`, and the route on a parent — were invisible precisely because nothing compared two pictures of the same fact.

**The `gap` rows are a separate question and must not ride along.** Sixteen obligations are unenforced today; turning them on at once would refuse a lot of history, and doing it in the same change would make every diff ambiguous — a difference could be the model being wrong or the grid being newly enforced. So the conversion reproduces today's behaviour exactly, gaps included, and enforcing a `gap` row is a later change with its own diff.

## Still open

| | |
| --- | --- |
| **where the snapshot is cached** | a file in `.logs/` is simplest. The risk is confined to reports by design, since nothing that decides reads a cache |
| **whether the cache is worth having at all** | a full fetch is 4.6s and only `turn-check.sh` runs often enough to care. A design with no cache is simpler, consistent by construction, and 4.6s slower for the two consumers that would notice. It should be costed before the cache is built |
| **the cost of the grid being executable** | generating `check-transitions.sh` is a rewrite of a working script. The safer order is: model reports first, generation later, and possibly never |
