# Triage

**Triage is joint. Never alone.** Raising a project folds and closes
requirements, and setting a stage or a milestone commits to a shape — none of
that is reversible cheaply. Present the questions and wait.

The rules live in [`CLAUDE.md`](../../../CLAUDE.md) and
[`docs/3.6`](../../../docs/3.6-change-lifecycle.md). This is the order to ask
in, and the things that are got wrong.

## The three passes

**1 · The minimum, before anything else.** Without these an issue is invisible
to every view:

| field | |
| --- | --- |
| a clear short description | the title is what is read in a list of forty |
| `Workstream` | who owns it. **Unset is the triage queue**, so leaving it blank is a state, not an omission |
| `Priority` | a judgement, deliberately not derived |
| `Type of change` | `bug · functional · cosmetic · documentation · tooling` |

**2 · Scope.** Options, dependencies, `Effort`. `Stage` moves to *Scope,
Options and Dependencies*.

**3 · Project planning.** The outcome is one of five:

| outcome | what it means |
| --- | --- |
| **solo project** | raise it — the `raise-project` skill |
| **grouped project** | fold it into one that exists |
| **straight to `main`** | a pre-approved change, no project |
| **on hold** | `Stage` = `On Hold`, and the body says what it waits for |
| **cancelled** | closed, with why |

## What carries a milestone

**This is the part most often got wrong**, so it is stated as a test rather
than a list.

| | milestone |
| --- | --- |
| a **requirement**, ordinarily | **none.** It is not a thing that ships |
| a **requirement** done directly, no project raised | **`pre-approved`** |
| a **parent project** | **none.** It has no delivery role |
| a **work package** delivering without an image | the previous semver **plus a letter** |
| a **work package** shipping in a release | the **semver** |
| work packages **released together** | **the same** milestone |
| a **pre-approved** delivery | **none**, and no issue — the row in the parent's delivery list is the record |
| a **decision** | **none.** It routes work; it carries none |

**`no-release` is provisional and must not survive the close.** It says *not a
release* before anybody knows how the change will reach `main`. Resolve it to
`pre-approved` or a letter **before the issue closes**, or the record of how
that change was delivered is lost. `check-transitions.sh` reports one that got
through.

**A delivery is a sub-project** (D51), so *project* above means the thing that
delivers. A project with a single delivery is its own package; a project with
several has one sub-project each.

**Which of the two, for a delivery:** did it have a **branch**? Then a letter —
it delivered, and the delivery needs a name and a row in
[`4.9`](../../../docs/4.9-delivery-log.md). No branch means it went straight to
`main`, which is `pre-approved` and makes no delivery.

**A Production Release always takes a branch, a pull request, a semver and a
log row**, whatever else is true — `main` is what gets deployed, so an unproven
release commit there blocks every other release.

## What goes wrong

**Setting `pre-approved` on a requirement that was folded.** Folded means a
project owns it now; the project carries the milestone and the requirement
carries none. The `folded` label is the signal.

**Leaving `no-release` on.** Sixty closed issues carried it on 2026-09-08 —
fifty-six requirements that should have had none, and four projects whose
letters were already written in `4.9` and never set on the issue.

**Triaging alone.** The most expensive mistake here, because folding closes
issues and un-folding is manual.

**Answering "does it reach users" from `Type of change`.** It is `Route`.
`documentation` and `tooling` are not the same question as *Repository Change*,
and reading one for the other made ten issues claim to reach users.

## Afterwards

```bash
./scripts/check-transitions.sh    # has it done the work its stage claims?
./scripts/actions.py              # is it now on somebody's list?
```

**An issue that is triaged and on nobody's list is the failure to look for.**
That is what the workstream and the stage are for.
