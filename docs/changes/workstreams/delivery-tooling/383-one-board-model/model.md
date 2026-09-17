<!-- markdownlint-disable-file MD013 -->
# The model: what it holds, who asks it, and why nothing is computed twice

For #383. Owner, 2026-09-17: *"python for the model so it can be structured to support each use case."*

This document designs the model. It does **not** restate the process: the flows, gates and checks are in [`flows.md`](flows.md), and what each issue type owes at each step is in [`obligations.md`](obligations.md). Those two are the description; this is what falls out of them.

The order matters and is the owner's: **describe the process, list its checks, gates, actions and decisions, and only then say what information the model must hold.** Designing the model first produces a data structure that is convenient to build and awkward to ask.

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
| **consumers** | the scripts | ask, format, decide what to do about the answer | compute anything |

The layer boundary that does the work is the third: **no consumer computes.** A consumer that needs to know whether an issue is a parent asks; it does not look at sub-issues.

## `is_parent`, end to end

The owner's example, and the one that has broken twice.

**1 · The process says it.** Two obligations in `obligations.md` name it: *a parent must not be at Development, User testing or Deployment*, and *a parent owes no route* — its work packages carry one each.

**2 · So a predicate is needed**, and it needs exactly one definition:

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

## What the model holds

Read out of the tables in `flows.md`, not invented here.

```python
@dataclass(frozen=True)
class Issue:
    number: int
    title: str
    body: str
    type: IssueType                  # Requirement | Project | Decision | None
    state: str
    fields: Mapping[str, str]        # by NAME, never by option id
    sub_issues: tuple[Issue, ...]
    parent: Issue | None
    milestone: str | None
    labels: frozenset[str]
```

and the derived facts, each defined once:

| derived | why it exists |
| --- | --- |
| `is_parent`, `is_work_package`, `is_standalone` | four gates and three checks branch on it |
| `route`, `phase`, `stage`, `decision_state` | resolved by name; every consumer matches option ids today |
| `commits_naming_it`, `commits_naming_its_parent` | kept apart — the `built` obligation, #375 |
| `owes` | the obligation list for this issue at its current step |
| `waiting_on` | `actions.py`'s whole purpose |
| `is_built`, `is_deliverable`, `is_closable` | one implementation of each; three scripts ask each today |

**Fields are resolved by name at the boundary.** Option ids appear in `sources/github.py` and nowhere else. Today five scripts carry hardcoded ids like `IFSS_kgDOAsQ80g`, which is a fact about the GitHub instance leaking into process logic.

## Latency is declared per consumption, and some consumptions refresh

Owner, 2026-09-16: *"Different points in the process need different latencies. A to do list differs from a production deployment gate."* And 2026-09-17: *"some checks should refresh the cache. So the latency requirement is something to be documented for each consumption."*

So latency is not a convention the caller remembers — it is **an attribute of the consumption, written down beside it**, in the same way `Route` is an attribute of an artefact. Four values, and the third is the one that was missing:

| freshness | means | who asks for it |
| --- | --- | --- |
| `CACHED` | whatever is there; the answer carries its age | reports, where a stale row is visible and harmless |
| `RECENT(n)` | cached if younger than `n`, else fetch | sweeps that run often and need not pay every time |
| `REFRESH` | fetch now, **and write the result to the cache** | anything that decides: every gate, and any check whose answer stops work |
| `AFTER_WRITE` | re-read following a mutation, ignoring the cache entirely | `settle`, where the point is to confirm what was just written |

**`REFRESH` updates the cache rather than bypassing it.** That is the change, and it is what makes the cache worth having: a gate that must fetch leaves the board fresher for every report behind it, instead of paying for a fetch and throwing it away. A deploy refreshes on its first gate, and the seven after it read a snapshot seconds old.

`AFTER_WRITE` is separate because it must **not** be served by the cache at any age, including one written moments earlier by the mutation's own optimistic update.

### The consumption register

Every point that asks the model appears here with its latency. A new consumption adds a row; a consumption without one is the defect, not the missing latency.

| consumer | consumption | freshness | because |
| --- | --- | --- | --- |
| `deploy.sh` | `on-remote`, `ci`, `pull-request`, `schema`, `version`, `milestone`, `preview`, `rehearsal` | `REFRESH` on the first, `RECENT(60)` after | eight gates in one run; the first pays, the rest read it |
| `deploy.sh` | *settle* | `AFTER_WRITE` | it confirms the write it just made |
| `verify.sh` | post-deploy obligations | `REFRESH` | it answers whether the deploy worked; a stale yes is the failure it exists to catch |
| `check-transitions.sh` | every obligation in the grid | `REFRESH` | it refuses transitions — the answer stops work |
| `sync-pr-state.sh` | read review decision, write field | `REFRESH`, then `AFTER_WRITE` | it reads to decide and re-reads to confirm |
| `status.sh` | the board report | `RECENT(300)` | a five-minute-old board is a correct board for reading |
| `actions.py` | what waits on the owner | `RECENT(300)` | the to-do list your rule names |
| `inbox.sh` | comments since a date | `RECENT(300)` | a conversation does not turn over in minutes |
| `turn-check.sh` | the per-turn sweep | `CACHED` | it runs constantly and must cost nothing; it reports, never refuses |
| `roadmap-diagram.py` | the diagram | `CACHED` | a picture, redrawn on demand |

Two things fall out of reading it as a table. Every consumption that **refuses** asks for `REFRESH`, and every consumption that **reports** does not — which is the gate-and-check distinction showing up again, this time as a cache policy. And `turn-check.sh` is the only `CACHED` consumer that runs unattended, which is exactly why it must not gate.

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

## What this replaces

| consumer | today | after |
| --- | --- | --- |
| `deploy.sh` | 18 GitHub call sites | gates call `board`, settle stays in bash |
| `check-transitions.sh` | 10 | generated from the grid |
| `verify.sh` | 8 | asks `is_built`, `is_deliverable` |
| `status.sh` | 7 | asks; formatting stays |
| `sync-pr-state.sh`, `inbox.sh`, `turn-check.sh`, `actions.py`, `roadmap-diagram.py` | 11 between them | ask |

**All nine, with no exemption.** `inbox.sh` asks the model for comments; the obligations grid still may not read them. The count that matters afterwards is `gh api` call sites outside `board/`, which should be zero.

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
| **where the snapshot is cached** | a file in `.logs/` is simplest; a gate asking `max_age=0` never reads it, so the risk is confined to reports |
| **whether `roadmap-diagram.py` should survive** | it has one call site and one reader. The job spec puts deleting in scope, and this is a candidate — but it is a `CACHED` consumer, so converting it is cheap and deleting it need not block the move |
| **the cost of the grid being executable** | generating `check-transitions.sh` is a rewrite of a working script. The safer order is: model reports first, generation later, and possibly never |
