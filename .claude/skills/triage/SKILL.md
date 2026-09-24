---
name: triage
description: Raise, title and triage any issue — requirement, project or decision. The minimum fields, how to write a short title that names the thing rather than teasing it, what carries a milestone, and when Claude triages alone. Use when raising or retitling an issue, or when sweeping the board for untriaged ones.
---

# Triage

**Triage is joint, except where D54 gives it to Claude.** Raising a project
folds and closes requirements, and setting a stage or a milestone commits to a
shape — none of that is reversible cheaply, which is why the default is to
present the questions and wait.

**Claude triages alone in Delivery Tooling and Process Definition, and for
type `tooling` or `documentation` in any workstream** — D54, accepted
2026-09-17. The limits are the job spec on #382, and the ones that bite here
are that anything reaching production, the product and game rules, and
anything irreversible outside git still come to the owner whatever their
workstream. Everything else in those areas is Claude's to classify, scope,
group, fold and close.

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

**A title is a short, pithy, memorable name, not a teaser.** Owner, 2026-09-24:
*"When I look at the board I want to quickly recall what each issue is about
without reading the body, a short memorable name containing the key words
related to the change would help."* #292's original title — *"The word lists:
one greylist for every edition, and a generated file nothing checks"* — reads
like a hook for the body to resolve, where it should simply have named the
file. Say what the thing is; curiosity belongs in a poster, not a board. This
applies to a project's title as much as a requirement's — #400 was renamed
from a full sentence to *TLE Scheduler* the same day. Retitle on sight when an
existing title fails this test, not only at raise.

**A first pass still says too much — cut further than feels natural.**
Owner, 2026-09-24, tightening a round of retitles further:

| issue | too long | short |
| --- | --- | --- |
| #224 | Monitoring and alarming: closing the remaining gaps | Monitoring and alarming gaps |
| #241 | Disaster recovery: untested VM rebuild | Test VM rebuild |
| #293 | Desktop client: is it a product, and where to get it | Desktop client download |
| #301 | Display name rules | User name format |
| #326 | Board tooling: verify matched field values still exist | Project Board: check field values exist |
| #360 | Rehearsal and production: infrastructure drift, no update procedure | VM updates |

Four things generalise from the set:

- **Drop the words that describe rather than identify.** *"closing the
  remaining"*, *"is it a product, and where to get it"*, *"verify … still
  exist"* — none of these narrow down which issue it is; the noun after them
  already does. A qualifier earns its place only if removing it would make two
  issues look the same.
- **Fold a short answer into the noun phrase; keep the colon only for a
  genuine two-part subject.** *"X: closing the gaps"* → *"X gaps"*. The colon
  survives in #326 because *"Project Board"* and *"check field values exist"*
  are still two different things to say — but each side is as short as it can
  be.
- **Name the actionable subject, not the symptom.** #360 was a description of
  *drift*; the title is the thing to do about it, *updates*. Ask what the
  issue is actually for, not what is currently wrong.
- **Pick the word a reader recognises with no other context, even over this
  codebase's own term, and especially where the game's own vocabulary would
  collide.** *Display name* is the precise internal term; *user name* is what
  means something out of context. *Board* on its own reads as the Scrabble
  board in this codebase; *Project Board* does not. Precision loses to
  disambiguation here — the body still carries the exact term.

The `#N MAIN PROJECT:`/`#N WP A:` prefix is structural — its own convention,
in [`docs/3.6`](../../../docs/3.6-change-lifecycle.md) — and is never cut;
these rules apply to what follows it.

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
that change was delivered is lost. `board-check.py` reports one that got
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

**Triaging alone outside D54's scope.** Folding closes issues and un-folding
is manual, so the cost of getting this wrong is asymmetric. Inside Delivery
Tooling and Process Definition, and for type `tooling` or `documentation`,
triaging alone is now correct; everywhere else it is still the expensive
mistake. Check the workstream and the type before deciding which case you are
in.

**Answering "does it reach users" from `Type of change`.** It is `Route`.
`documentation` and `tooling` are not the same question as *Repository Change*,
and reading one for the other made ten issues claim to reach users.

## Afterwards

```bash
./scripts/board-check.py    # has it done the work its stage claims?
./scripts/board-actions.py  # is it now on somebody's list?
```

**An issue that is triaged and on nobody's list is the failure to look for.**
That is what the workstream and the stage are for.
