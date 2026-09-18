<!-- markdownlint-disable-file MD013 -->
# The reports: what each is for, and what it must therefore say

For #383. Owner, 2026-09-17: *"the requirements come from the change flows and the reports. The reports should therefore be listed with purpose and then worked up to content."*

With [`flows.md`](flows.md) and [`obligations.md`](obligations.md) this completes the description. [`model.md`](model.md) is what falls out of all three.

**Purpose first, then content.** A report written from its purpose says what someone needs; a report written from what is easy to query says what the tooling happens to know. The nine scripts running today were written the second way, which is why three of them answer the same question differently.

**This list is not derived from the scripts.** Where a report resembles one, that is noted at the end of its section as an implementation fact, not as its definition. Two of the reports below do not exist today.

---

## R1 · What needs the owner

**Purpose.** The owner never has to scan the board to find what is waiting on him. Everything else is Claude's to find and move.

**Content.** One list, ordered by how long it has been waiting. Each line names the issue, what is being asked, and how long it has waited. Nothing else: a report that also says what is going well is a report that gets skimmed.

| the report must know | why |
| --- | --- |
| whose turn it is | the whole purpose |
| how long it has been that way | ordering, and the only signal that something is stuck |
| what is being asked | so the owner can answer without opening the issue |

**Whose turn** is a derived fact with four sources: `Decision State` on a decision, `reviewDecision` on a pull request, an unanswered question in a body, and a phase that only the owner can advance. Today these are read by two scripts that disagree about the third.

**Empty is the expected state** and must be said plainly, not left as blank space.

*Today: `actions.py`.*

---

## R2 · What has changed since I last looked

**Purpose.** Someone returning after a day or a week can find what moved without reading the board.

**Content.** Grouped by issue, most recent first: comments, state changes, and what the owner himself typed — marked, because his own words are what he is most likely to be looking for. Bounded by a date, defaulting to the last run.

| the report must know | why |
| --- | --- |
| comments, with author and timestamp | the subject of this report *is* the conversation |
| issues opened and closed in the window | a state change is a change |
| which comments are the owner's | he is usually looking for his own thread |

**This is the one report that reads comment threads.** Everything else reads bodies and fields, because evidence and conclusions belong in the body. That is a rule about where evidence lives, not about what the model may fetch.

*Today: `inbox.sh`.*

---

## R3 · Where the programme stands

**Purpose.** Answer, without opening GitHub: what is in flight, what would a release ship, and what is behind.

**Content.** Four blocks, in this order because it is the order the questions get asked:

1. **the environments** — what production, rehearsal and preview are running, and how far behind `main` each is
2. **what a release from `main` would ship** — the changes reaching users, separated from those already live and those that reach users at merge
3. **open changes** — one line each, with the state derived from branches and commits rather than from a field somebody remembered to set
4. **anything overdue** — documents never reviewed, post-deployment checks unanswered

| the report must know | why |
| --- | --- |
| deployed versions, live | block 1 |
| commits since the last release, and what each references | block 2 |
| route, per work package | block 2 — which changes reach users |
| branch and commit state per issue | block 3 |
| review ages | block 4 |

**The separation in block 2 is the whole value.** A Repository change is live at merge and must not appear under *would ship*; a parent has no route and must not appear under *cannot say*. Both were wrong in the version that existed before this design.

*Today: `status.sh`.*

---

## R4 · Is this issue complete for what it is and where it is

**Purpose.** Catch an issue that cannot progress, before it blocks something. Owner, 2026-09-17: *"One report should check the contents of each issue against type and state/phase."*

**Content.** Per issue: its type, its step, and every obligation that step carries, each answered **met**, **missing** or **not checked**. Then a summary by type and step, so a step that is always incomplete is visible as a pattern rather than as forty separate findings.

| the report must know | why |
| --- | --- |
| issue type, and its step — `Stage`, `Phase` or `Decision State` | the grid is indexed by both |
| the obligations for that cell of the grid | this report **is** the grid, rendered |
| the evidence for each: body headings, fields, git, GitHub | each obligation names where it is evidenced |
| whether an obligation is enforced today or a `gap` | so a `gap` reads as *not checked*, not as *met* |

**A defaulted field is the first thing this report says, not the last.** Owner, 2026-09-18: untyped becomes a `Requirement`, and a requirement with no `Stage` becomes `Triage`. Those defaults keep the issue inside the rules — an issue outside every rule keyed on type is skipped by all of them and reads as compliant, which is #361, where twenty sat unnoticed.

But the default must not become the quiet answer, so R4 reports it:

| | reads as | is |
| --- | --- | --- |
| silently defaulted | no findings | drift, invisible |
| defaulted **and flagged** | one finding until corrected | visible, and workable meanwhile |

The finding says the field was unset and what it was taken to be, because an issue raised outside the three templates is worth knowing about even once it has been made workable. `board fix defaults` writes the value back so GitHub agrees with the model.

Measured 2026-09-18: **zero untyped open issues, and zero of the sixteen open requirements with `Stage` unset.** So both are prevention. Two routes keep them necessary — a blank issue from the GitHub UI, which no `config.yml` disables, and the API, which requires no type.

**This is the report that does not exist today**, and its absence is why the grid in `obligations.md` could sit with a wrong row in it. Twenty-eight obligations, twelve enforced: this makes all twenty-eight visible, and the sixteen unenforced ones answer *not checked* rather than silently passing.

**It is a report and not a gate**, at least first. Sixteen obligations arriving as refusals would refuse most of the open board. A gate refuses and work stops; a check reports and a person decides, and this starts as the second.

---

## R5 · Can this deployment proceed

**Purpose.** Refuse a deployment that would ship something untested, unbuilt, or not what it claims to be.

**Content.** The eight gates of `flows.md`, in order, each pass or refuse with the reason. First refusal stops the run.

| the report must know | why |
| --- | --- |
| the target sha, and that `origin` has it | `on-remote` |
| CI and pull-request run conclusions for that sha | `ci`, `pull-request` |
| migrations in the image against the database | `schema` |
| semver across tree, milestone and tag | `version` |
| every open issue in the milestone, and whether a commit builds it | `milestone` |
| preview and rehearsal versions, live | `preview`, `rehearsal` |

**This is the one consumer where a stale answer causes damage**, so it refreshes rather than reading a cache, and a source that cannot answer refuses rather than passing.

*Today: `deploy.sh`.*

---

## R6 · Did the deployment do what it was for

**Purpose.** A release is not finished when it ships; it is finished when someone has checked it did what it was raised to do.

**Content.** Per work package in the milestone: its post-deployment checks, each answered `passed`, `cannot be tested` or `failed`, and the requirement each answers.

| the report must know | why |
| --- | --- |
| the milestone's work packages | scope of the check |
| the post-deployment table in each body | the checks themselves |
| unticked boxes anywhere in the package | the `closable` obligation |

*Today: `verify.sh`, partly.*

---

## R7 · Where the model and the scripts disagree

**Purpose.** Temporary. Across the move to the model, catch any consumer that starts saying something different.

**Content.** One line per disagreement: the consumer, the issue, what each says. Empty is the goal and the expected state within a week.

**Retired when the move is complete.** A report with a scheduled death should say so in its own output.

---

## What the reports need that the flows do not

Reading R1 to R7 against `flows.md`, the reports ask for four things the gates never do:

| | asked by | |
| --- | --- | --- |
| **age** — how long has this been waiting | R1, R3 | a gate asks *is it true now*; a report asks *for how long* |
| **comments** | R2 | the only report whose subject is the conversation |
| **history** — what changed in a window | R2, R3 | a gate reads the present |
| **the grid rendered per issue** | R4 | the gates each read one cell of it |

Those four are the difference between a model that serves gates and one that serves reports, and they are why the requirements come from both.
