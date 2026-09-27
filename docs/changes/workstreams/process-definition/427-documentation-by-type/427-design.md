# 427 Documentation by type: design

The target shape of each numbered document, set before anything moves. #427
owns the requirements; this note owns how they are met.

## The rule (R1)

A numbered document holds one kind of content, by its group, adopting the
Diátaxis types:

| group | Diátaxis type | holds |
| --- | --- | --- |
| 1.x | explanation | what the system is and where it is going |
| 2.x | explanation | the model of a subsystem, and its constraints |
| 3.x | how-to guide | the step, the command or the rule, then its notes |
| 4.x | reference | every current value, and nothing else |

In every group: what is true now, with at most a line of reason. History,
argument and quotations go in the issue or the commit. The four kinds of
evidence docs/3.9 names are the exception: kept when a reader would otherwise
do the wrong thing.

Documents outside the numbered set keep their own types: change notes (this
one), periodic reports, templates, generated maps.

## Target shapes

In the review's order of leverage.

| document | now | target |
| --- | --- | --- |
| `README.md` | 200 lines: index, doctrine, and a stale *Current Direction* | a short entry point: the groups with their types, an index by task, the two rules every reader needs, links. The doctrine moves to a new `3.9 Writing documents` |
| `2.5` | a status ledger dated 2026-07-24, then the original design "read as direction" | the current authentication model only, as explanation; the design history leaves |
| `2.6` | worked request and response examples | unchanged in type; checked against 2.5 and 4.3 for overlap |
| `2.7` | seat claims and invitations, partly behaviour, partly walkthrough | the invitation model as explanation; walkthroughs to 2.6 |
| `3.1` | developer setup and production host provisioning | developer setup only; provisioning moves to `3.4` |
| `3.6` | 3,029 lines of rules, rationale and case history | the rules and the procedure; rationale reduced to a line each; case history left in the issues it came from |
| `4.8` | a register, with process taxonomy | the register only; the taxonomy moves to `3.6` |
| `3.3`, then the rest | mixed to varying degrees | as R1 |

## Order of work

1. Done: R1 into `3.9` and `CLAUDE.md`; R2, the README; R3, the
   authentication pilot; R4, `3.1`.
2. `3.6` in passes, one part a commit, then `4.8`, whose process material goes
   to `3.6`'s new shape rather than to its old one.
3. `3.3` and the rest.
4. R8, the signal count.

## What the pilot showed

- A 2.x document carrying request and response detail duplicates 4.3, and
  loses it.
- A dated status ledger becomes the current model, each value checked against
  the code before it is kept.
- Intentions ("next steps", "future enhancements") leave for issues, listed on
  #427 for the owner rather than deleted silently.
- Restructuring finds wrong facts: 4.3 described a behaviour the code does not
  have. A document is checked against the code, not against another document.

## 3.6 and 4.8

`3.6` is 3,029 lines in three parts: the flow, the rules, and notes on release
scope and versions. Target:

| part | now | target |
| --- | --- | --- |
| opening | *Why this process exists*, 56 lines of argument | a paragraph: what the document holds, and that `CLAUDE.md` is its one-page summary |
| 1, the flow | the flow, with *1.1 What a milestone says* at 607 lines | the flow and its steps; 1.1 split into milestones, deliveries and work packages, each rule stated once |
| 2, the rules | 23 rules, each with its history | each rule and a line of reason; incidents and dates to the issues they came from |
| templates inline | the triage comment and the dependencies heading, fenced in the text | `docs/templates/`, per `CLAUDE.md`, linked from the rule |
| 3, notes | release scope, the two version numbers, priority's reversal, why deploy needs no approval | versions to `4.1`'s versioning; what remains a rule into part 2; history removed |
| from 4.8 | *Every way a change is categorised*, *The route an artefact takes* | merged with 3.6's *Type of change* and *Classifying a change*, one home for each scheme and for the routes; `shipping.py`'s docstring and `CLAUDE.md` repointed |

`4.8` then keeps its registers (the host, Oracle Cloud, GitHub, what the
tooling reads) and the exit-status convention, as reference.

Nothing is lost: what leaves a document is either already in an issue or a
commit, or goes into the commit that removes it.
