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

1. R1 into `3.9` and `CLAUDE.md`; R2, the README.
2. The authentication pilot, 2.5 to 2.7, to find the pattern on a contained
   subject.
3. `3.1`, `4.8`, then `3.6` in sections, then `3.3` and the rest.
4. R8, the signal count, once the pilot shows which phrases matter.

Nothing is lost: what leaves a document is either already in an issue or a
commit, or goes into the commit that removes it.
