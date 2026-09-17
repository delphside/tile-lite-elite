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

## Freshness is part of the contract

Owner, 2026-09-16: *"Different points in the process need different latencies. A to do list differs from a production deployment gate."*

So the snapshot carries its own age and the caller declares what it tolerates:

```python
snap = board.snapshot(max_age=0)        # a gate: fetch now, or fail
snap = board.snapshot(max_age=300)      # a report: five minutes is fine
```

`flows.md` already assigns a latency to every gate — all `current`, except *settle*, which is **re-read after write**. Those become the arguments, not a convention. A gate asking for `max_age=0` and being handed a cached snapshot is a bug the type system can catch; a gate reading a stale report today is silent.

## Partial failure, which `flows.md` left open

> *what the snapshot says when GitHub answers and git stays silent. Today each script decides for itself, mostly by exiting 0*

Exiting 0 on a failed source is the worst available answer: a gate that cannot see the data reports that it found no problem. The model's answer:

```python
class Unavailable(Exception):
    """A fact was asked for whose source did not answer."""
```

Each source records `ok` or `failed`. A derived fact whose source failed **raises**; it never returns a default. The consumer decides what that means, and the two answers differ by design:

| consumer | on `Unavailable` |
| --- | --- |
| a **gate** | refuse — "cannot say" is not "no problem" |
| a **report** | print `cannot say` in the row, and carry on |

That distinction is already the project's rule — *a gate refuses and work stops; a check reports and a person decides* — applied to missing data rather than to findings.

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

`inbox.sh` keeps its own reading of comment threads: its subject *is* the conversation, and the model deliberately reads only bodies and fields.

## Parallel running, because 16 new checks would refuse a lot of history

The grid's `gap` rows are unenforced today. Turning them on at once would refuse most of the open board.

So the model ships **reporting only**: it computes every obligation, the existing scripts keep gating, and a nightly diff reports where the two disagree. A row moves from `gap` to `now` when the diff has been empty for a week and the backlog it would refuse is cleared. That is also how the model earns trust before anything depends on it.

## Still open

| | |
| --- | --- |
| **where the snapshot is cached** | a file in `.logs/` is simplest; a gate asking `max_age=0` never reads it, so the risk is confined to reports |
| **whether `roadmap-diagram.py` should survive** | it has one call site and one reader. The job spec puts deleting in scope, and this is a candidate |
| **the cost of the grid being executable** | generating `check-transitions.sh` is a rewrite of a working script. The safer order is: model reports first, generation later, and possibly never |
