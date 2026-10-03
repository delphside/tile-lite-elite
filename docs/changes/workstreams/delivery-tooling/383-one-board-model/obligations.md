<!-- markdownlint-disable-file MD013 -->
# What each issue type owes at each lifecycle step

For #383. Owner, 2026-09-16: *"Each issue type has defined requirements for each lifecycle step."*

This is `owes` specified rather than described. Today the same question is asked by `check-transitions.sh`, by `verify.sh` and by `actions.py`, each covering a different part of this grid and none of them stating the grid. Writing it down is what lets one model answer it once.

**Purpose before criteria**, per the owner's rule on the same day. Each row says what the step is *for*; the obligation follows from that, and the criterion is how the obligation is evidenced.

**Status column**: `now` is enforced today, `gap` is owed by this grid and checked by nothing, `n/a` is deliberately not checked.

## Where evidence lives

Owner, 2026-09-16: *"All issues should obey the rule that discussion is in the comments but evidence and conclusions are in the body. So you only need to read the body."*

So there are four places an obligation can be evidenced, and only four:

| | |
| --- | --- |
| **body** | a heading, a table, a tick — the conclusion, never the argument |
| **field** | workstream, phase, stage, route, type of change, priority, effort, decision state |
| **git** | commits, trailers, tags |
| **GitHub** | milestone, sub-issues, pull request, review decision |

Nothing reads comment threads. `inbox.sh` is the one exception and is outside this grid, because its subject *is* the conversation.

## Requirement, by `Stage`

A requirement's job is to become well enough understood to be planned, and then to be taken up by a project.

| stage | what the step is for | owes | evidence | status |
| --- | --- | --- | --- | --- |
| Triage | the inbox, and deciding whether to keep it | a title a stranger can act on | body | `gap` |
| Triage | decide whether to keep it, and place it | workstream, type of change, priority | field | `now` |

**There is no unset `Stage` row.** Owner, 2026-09-18: *"Requirements with unset state are set to Triage."* So `Triage` is the inbox rather than a stage after it, and a requirement always sits somewhere in this table. An unset stage was a row that every rule skipped, which is the same shape of defect as an untyped issue.

| Scope, Options and Dependencies | know the size and the shape, and that the option is feasible | effort; options named while open; dependencies named | field, body | effort `now`, rest `gap` |
| On Hold | the stall is visible and attributable | something named under dependencies | body | `now` |
| Ready for Project | it can be planned without re-reading it | scope, option chosen, effort — and nothing unresolved | body, field | `gap` |
| Candidate Project 1 · 2 · 3 | it is grouped with what it will be raised beside | same number as its group; route known | field | `gap` |
| *closed as folded* | the project owns it from here | `folded` label, parent set, a comment naming the project | GitHub | `now` |

**The candidate stages check nothing today.** A requirement can sit in `Candidate Project 2` with no route and no effort, and nothing says so.

## Project (parent), by `Phase`

A parent owns requirements, design and documents. Owner: *"The parent runs Scope, the queue, and Design and Test Approach, then stops — oversight is a design role."*

| phase | what the step is for | owes | evidence | status |
| --- | --- | --- | --- | --- |
| Scope | what the project does, and which technical option | `## Requirements`, `## Design` headings; sources listed ⟺ parented. **No route** — a parent has no delivery role, and its work packages carry one each | body, GitHub | `now` |
| Q3 · Q2 · Q1 | a queue position that means something | a position, and nothing regressing | field | `n/a` |
| Design and Test Approach | design settled, test approach defined | `## Test approach` with both lists; `## Impacted artefacts`; `## Deliveries` | body | `now` |
| Development | — | **a parent must not be here** | field + `is_parent` | `now` |
| User testing | — | **a parent must not be here** | field + `is_parent` | `now` |
| Deployment | — | **a parent must not be here** | field + `is_parent` | `now` |
| Post-deployment | a requirement no single delivery satisfies is answered | one row per requirement, each answered | body | `gap` |
| Project Closedown | the lesson is captured while it is still remembered | lessons learnt; no unticked boxes; every child closed | body, GitHub | partly `now` |

**A parent owes no route, and this grid said it did until 2026-09-17.** The row above asked for one at `Scope`, which is the same defect `status.sh` carried and is why it is worth recording here: the grid is meant to be the single statement of what is owed, so a wrong row in it would have been copied into whatever the model generates. A parent is a project whose sub-issues include projects — not one with any sub-issues, since a project carries folded requirements routinely.

**A parent and its work packages both owe the test approach, and either may point at the other.** Owner, 2026-09-18:

> Both, but one will point at the other. All docs will be stored in the parent project folder, or in the bodies. They can be organised however works best and both parent and work package describe where it is.

So the obligation is **to say where it is**, which a pointer satisfies and an absent heading does not. That reading is stricter than it sounds: a heading with nothing under it is the same silence with a title on it, and is not an answer. `CLAUDE.md` adds *"the content or a link to the design document that holds it, never both"* — the "never both" half is not checked, because telling a summary from a duplicate needs judgement and a check that guessed would cry wolf.

## Work package, by `Phase`

A work package carries its own artefacts, test approach and post-deployment checks, because a check is answered per delivery.

| phase | what the step is for | owes | evidence | status |
| --- | --- | --- | --- | --- |
| Scope | what this delivery delivers | a link to the parent's design, not a copy | body | `now` |
| Design and Test Approach | this delivery is testable | its own test approach; impacted artefacts | body | `now` |
| Development | it is being built where it can be held back | branch exists; branch chain matches the route | git, field | `gap` |
| User testing | somebody has used it | Preview boxes ticked or answered | body | `now` |
| Deployment | it reaches users by its route | milestone set; commits naming it | GitHub, git | `now` |
| Post-deployment | it did what it was for | one row per requirement, answered `passed` / `cannot be tested` / `failed` | body | partly `now` |
| Project Closedown | the delivery's lesson is captured or delegated | lessons learnt, or a statement that the parent carries them | body | `gap` |

**`built` is the obligation with three implementations.** `verify.sh` and `deploy.sh` ask whether a milestone's issues are backed by commits, and disagreed about parentage until #370 and #375. It belongs here once.

## Decision, by `Decision State`

**A decision owes no milestone, and nothing should ask it for one.** Owner, 2026-09-18: *"Decisions don't get milestones. They aren't delivered. They may be children of projects that do the delivery."* `CLAUDE.md` already said it — *"it takes no semver and no letter milestone, and no delivery-log row"* — and `status.sh` asked anyway, falling through to *"merged, awaiting release"* because a decision carries no `Type of change` to branch on. D54 sat under that label on 2026-09-18, awaiting a release it can never be in.

That is the third artefact caught being asked for something it does not have, after a requirement and a parent project. The shape is always the same: a consumer reads a field the artefact never carries, finds nothing, and reports the absence as a defect in the issue rather than in the question.

A decision **may** have a parent, where a project carries out what it decided. That is how the delivery is tracked, and its absence is not a defect.

| state | what the step is for | owes | evidence | status |
| --- | --- | --- | --- | --- |
| Asked | the question is answerable as put | a question, options, and what turns on it | body | `gap` |
| Feedback Provided | the owner has said something | the response recorded in the body, not only in comments | body | `gap` |
| Documented Ready for Sign-Off | the answer is written where it will be found | the decision written in its owning document | body | `gap` |
| Decided | it is settled | the agreed answer in the body | body | `now` |
| Actioned | it changed something | *applied in the same commit that marks it answered, or an issue raised and named* | git, body | `gap` |

**Only one of the five is checked today**, and the check is the weak direction: `check-transitions.sh` reports a decision whose body reads as agreed while the field still says `Asked` — which is #382's current flag. Nothing checks that `Actioned` actually actioned anything.

## Pull request, by `PR State`

Owner, 2026-09-18: *"Pull Request is a particular type of issue in GitHub. All four types have templates which should be present on creation."*

A pull request is what gives a review its mechanics: a diff, a place to comment, a recorded approval, a merge that waits for a tick. Its body is the review surface.

| state | what the step is for | owes | evidence | status |
| --- | --- | --- | --- | --- |
| Drafting | the work is visible before it is ready to judge | a linked issue — `Refs #N` or `Closes #N` | body | `gap` |
| Awaiting review | the reviewer can tell what is being asked | **what is being requested**; **what is deliberately left out**; owner added as reviewer | body, GitHub | `gap` |
| Changes requested | the ask is recorded where the state is | the change noted under its own review item | body | `gap` |
| Approved | it can merge | the review ticked; CI and e2e green for the head sha | GitHub | `now` |
| merged | the record survives the branch | `Refs #N` in the commits; milestone or `pre-approved` resolved | git, GitHub | partly `now` |

**Only one of the five is checked today**, and it is the one GitHub enforces for us. The two headings at `Awaiting review` are the owner's rule of 2026-09-17 and were in no template until 2026-09-18, so a pull request could reach review saying neither.

**`Changes requested` has a mechanical trap already documented in `CLAUDE.md`**: making the changes without re-requesting the review leaves the board reading `Changes requested` and the work waiting on nobody. That is a `gap` this grid can close, because both halves are visible — the review state and whether a re-request followed.

## Closedown as a skill with a hook

Owner, 2026-09-16: *"Closedown is a skill with a hook."*

Closedown is the last row of every grid above, and it is the row most often skipped, because by then the work is done and the interest has moved on. Two halves:

**The skill** walks what the grid says is owed at `Project Closedown` — lessons learnt written, every box ticked or answered, every child closed, the post-deployment table complete, the delivery-log row present — and writes the review from the template. It is a checklist with the answers already gathered, which is exactly what the model makes cheap.

**The hook** is what stops it being optional. The natural trigger is the `Phase` moving to `Project Closedown`, but a hook cannot see a field change on GitHub. Two candidates that can:

| trigger | catches | misses |
| --- | --- | --- |
| a commit closing an issue typed `Project` | closing by commit | closing by hand in the UI |
| the sweep already running in `turn-check.sh` | everything, eventually | immediacy — it reports rather than blocks |

The second is what exists and it is a check rather than a gate. Making closedown a gate means refusing something, and the only thing left to refuse at that point is the close itself — which no hook here can do.

**So the honest shape is: the skill does the work, and the sweep says when it is owed.** That is weaker than the owner's word *hook* implies, and it is worth saying so rather than building something that appears to gate and does not.

## What this grid changes

Counted from the status columns: **28 obligations, of which 12 are enforced today and 16 are not.** The gaps cluster in three places, and each is a place a defect has already come from:

| | |
| --- | --- |
| the candidate stages | nothing checked at all, and it is where grouping decisions are recorded |
| decisions after `Decided` | nothing checks that an `Actioned` decision changed anything |
| closedown for work packages | the parent's closedown is checked; a package delegating to it is not |

## Still open

| | |
| --- | --- |
| **is the grid the requirement, or a description of it?** | if it is the requirement, `check-transitions.sh` should be generated from it rather than agreeing with it by hand |
| **what a `gap` costs** | sixteen new checks would refuse a lot of history. They should arrive as reports first, which is what parallel running is for |
| **the branch-chain obligations** | `Development` owes *branch chain matches the route*, which needs the owner's route-and-branches model settled first |
