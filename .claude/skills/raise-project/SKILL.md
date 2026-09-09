---
name: raise-project
description: Raise a project issue with the seven headings, set its fields, and fold the requirements it takes. Use when a project is being raised, or a requirement is being converted into one.
---

# Raising a project

The mechanics only. **What goes in the project is a judgement and is not here** —
the rules are in `CLAUDE.md` and `docs/3.6`, and the groupings are agreed with the
owner, never assumed.

## Before anything

**Triage is joint.** If the grouping has not been agreed, ask. Raising a project
folds and closes requirements, which is not trivially reversible.

**Straight to project is allowed** when the shape is already clear: no
requirement needs raising first. Converting an existing requirement is equally
fine — edit its body into the seven headings and change its type.

## The seven headings

**A parent and a work package owe different halves of these** — D51. A project
with no work packages is a parent that happens to have one delivery, and carries
all seven.

| heading | parent | work package |
| --- | --- | --- |
| Requirements | **owns** | links |
| Design | **owns** | links, adding only what is its own |
| Impacted artefacts | — | **owns**, and the parent repeats each package's table under its Deliveries list |
| Test approach | — | **owns** |
| Dependencies and related work | **owns** | links |
| Deliveries | **owns** — the list, each row a sub-project or `pre-approved` | its own steps |
| Post-deployment checks | only for a requirement no delivery satisfies | **owns** — a check is answered per delivery |

**`check-transitions.sh` asks each for what it owes**, telling them apart by the
parent link, so a one-commit delivery is not made to carry a Requirements table.

Each heading holds the content or a link to the document that holds it, never
both:

```markdown
## Requirements

**Source requirements**: #nnn, #nnn.

| | from | |
| --- | --- | --- |
| R1 | #nnn | what must be true when this is done |

## Design

## Impacted artefacts

*One table per delivery, three rows, one per route. `Route` is a property of the
artefact (`docs/4.8`), so a delivery is the mixture of routes it touches — and
that mixture is what decides the process it follows. Say `no` and a dash rather
than dropping a row: an absent row and an empty one read the same, and only one
of them means "nothing here".*

### Delivery 1 — <what it delivers>

| route | in this delivery | artefacts | branch | PR |
| --- | --- | --- | --- | --- |
| **Production Release** | yes/no | | **always yes** | **always yes** |
| **Other** | yes/no | | | |
| **Repository Change** | yes/no | | | |

*A **Production Release** row set to yes forces a branch and a pull request for
the whole delivery — `main` is what gets deployed, so a release commit there
cannot be guaranteed to work and blocks every other release until it is.*

*The other two rows take a branch only where the old version is needed while the
work is in progress. A document-only change never takes one: they live too long,
`main` moves, and the review does not happen.*

*The branch and PR columns answer **yes or no first**, then say which — `yes —
rides the same branch`, `yes — rides #341`. A cell that only explains has not
answered the question the column asks.*

*One branch serves the delivery, not one per row. Where a Production Release row
is yes, the other rows are **also yes**, riding that same branch and pull
request — everything the delivery touches goes on it, documentation included.*

## Test approach

### Functional user tests — Preview

- [ ]

### Technical tests — Rehearsal

- [ ]

## Dependencies and related work

## Deliveries
| # | what it delivers | milestone | steps |
| --- | --- | --- | --- |

## Post-deployment checks against requirements
| requirement | how the check is done | |
| --- | --- | --- |
```

**The source requirements are listed as well as parented.** Owner, 2026-09-08:
*"a project should list its source requirements as well as parenting them. This
is separate from the requirements table because that might move on during project
scoping."*

| | is | changes when |
| --- | --- | --- |
| **Source requirements** | the issues this project took, by number | a requirement moves in or out. It matches the `Requirement` sub-issues exactly |
| the **Requirements table** | R1…Rn, what must be true when this is done | scoping restructures them — two sources merge into one R, one splits into three, a source is dropped as out of scope |

**The `from` column is not a substitute.** It says which source produced an R,
which is useful and which stops being complete the moment scoping merges or drops
one. The source list is provenance and does not move; the table is the current
statement of the work and does.

**A decision is not a source requirement.** It routes work — it raises or adds
requirements and is then closed — so it is named in the `from` column of the
rows it produced, never in the source list. #301 listed decision #332 there on
2026-09-09 and `check-transitions.sh` reported it as a source with no parent
link, which is exactly right: nothing folds a decision.

**A project raised directly says so** rather than leaving the line out — `none —
raised directly as a project, so R1 and R2 are its own`. An absent line cannot be
told from an unanswered one, which is the same reason a test approach that does
not apply says *"None."*

**The two must agree with the sub-issues.** A requirement parented here but not
listed, or listed but parented elsewhere, is the defect that put #130 and #151
under #294 while #290 claimed them.

**A work package is a sub-project; a milestone is what groups them** (D51). A
work package is a `Project` whose parent is this one, carrying its own milestone,
artefacts, test approach and post-deployment checks. **Every change has a
delivery** — it has to reach main — but only a delivery made at one point in
time takes a **milestone**, and packages sharing one go live together. The
milestone never has an issue of its own. The parent owns the requirements,
the design and the documents, carries no milestone, and lists its deliveries:
each row names the work packages it carries, or says `pre-approved`.

**Four cases decide whether a sub-project is needed at all** — the owner's, and
`docs/3.6` carries them:

| | work packages | sub-projects |
| --- | --- | --- |
| **A** | one, one delivery | **none.** The parent is the work package and carries the milestone |
| **B** | two, going live together | two, **the same** milestone; the parent lists one delivery carrying both |
| **C** | two, going live separately | two, **different** milestones; two deliveries |
| **D** | three, two together | three; two deliveries, one carrying two packages |

**Case A is the common shape.** Do not create a sub-project for a project with
one delivery — the parent and the child would say the same thing.

## Naming

| | form |
| --- | --- |
| a parent | `#N MAIN PROJECT: <what it is>` |
| a work package, alone in its delivery | `#N WP A Del 1 of 2: <what it delivers>` |
| a work package sharing its delivery | `#N WP A Del 1 of 2, pt 1 of 2: <what it delivers>` |
| a work package whose deliveries are not yet decided | `#N WP A: <what it delivers>` |

`WP A` is which package, lettered so it never reads as a delivery number.
`Del 1 of 2` is which delivery carries it. `pt 1 of 2` is its share of that
delivery and **is omitted when the delivery carries one package** — `pt 1 of 1`
says nothing. It is what makes a shared delivery visible from a listing.

The parent's number is repeated in every child so a title sort groups the family.

**A delivery's steps live in one place** — in its sub-project, or under the
parent's list for a pre-approved one. Never both.

**The design starts with the as-is.** How the thing works today, then how it
will work. Owner, 2026-09-03: *"sometimes, especially with the scripts, I don't
know how they currently work which makes it difficult to understand the
change."* Reading the code to find out is the author's job, not the reviewer's.

**The two test headings are matched literally** by `verify.sh`, which counts
unticked boxes. Write "None." under one that does not apply rather than removing
it.

**A post-deployment check says how it is done**, not what is being checked, and
is answered `passed`, `cannot be tested`, or `failed`.

**Only rejected options are omitted.** While options are open, number them and
say what each constrains; once one is chosen only it survives in the body, and
the reasoning goes in a comment.

## Writing the body

**Never hard-wrap a paragraph in an issue body.** GitHub Flavoured Markdown
renders a single newline as a line break, so a paragraph wrapped at 76 characters
comes out ragged and half the width — unlike the repository's documents, where
markdownlint requires the wrapping. One paragraph is one line, however long.

Structural lines are unaffected and keep their own line: headings, table rows,
list items, block quotes and fenced code.

**Found 2026-09-09**, by the owner reading a paragraph that would not fill the
width. Nine issue bodies had been written document-style and needed unwrapping.

## Creating it

Always `--body-file`. A body passed with `--body` has its backticks evaluated by
the shell, which has silently swallowed whole spans twice.

```bash
NUM=$(gh issue create -R delphside/tile-lite-elite \
        --title "..." --body-file /tmp/body.md | grep -o '[0-9]*$')
id=$(gh api graphql -f query="{repository(owner:\"delphside\",name:\"tile-lite-elite\"){issue(number:$NUM){id}}}" \
       -q '.data.repository.issue.id')
```

Then set the type — a project is not a project until this is done:

```bash
gh api graphql -f query='mutation($i:ID!,$t:ID!){updateIssue(input:{id:$i,issueTypeId:$t}){issue{number}}}' \
  -f i="$id" -f t="IT_kwDOEyOvmc4yo-D_"
```

| type | id |
| --- | --- |
| Requirement | `IT_kwDOEyOvmc4yo-D-` |
| Project | `IT_kwDOEyOvmc4yo-D_` |

## Setting fields

`issueFields` takes a **list**, and several can be set at once. The singular
`createIssueFieldValue` refuses when a value already exists — use this one.

```bash
gh api graphql -f query='mutation($i:ID!){setIssueFieldValue(input:{issueId:$i,issueFields:[
  {fieldId:"<field>",singleSelectOptionId:"<option>"}
]}){issue{number}}}' -f i="$id"
```

A new project takes `Workstream`, `Phase` (usually `Scope`), `Effort` and
`Priority`. `Route` when it is known. Approval is the `pre-approved` **milestone**, not a field — there is no `Pre-approved` field, it was deleted on 2026-09-04.

| `Workstream` | `IFSS_kgDOAsE6Iw` |
| … Application & Game Architecture | `IFSSO_kgDOBNJpRg` |
| … Game Rules | `IFSSO_kgDOBNQ2zQ` |
| … Engine Player | `IFSSO_kgDOBNJpRw` |
| … Client UI | `IFSSO_kgDOBNJpSA` |
| … Client Management | `IFSSO_kgDOBNJpSQ` |
| … Authentication & Authorisation | `IFSSO_kgDOBNJpSg` |
| … Capacity Planning | `IFSSO_kgDOBNJpSw` |
| … Operations & Infrastructure | `IFSSO_kgDOBNJpTA` |
| … Delivery Tooling | `IFSSO_kgDOBNJpTQ` |
| … Process Definition | `IFSSO_kgDOBNJpTg` |
| `Type of change` | `IFSS_kgDOAr-w2g` |
| … documentation | `IFSSO_kgDOBM-znA` |
| … tooling | `IFSSO_kgDOBM-zng` |
| … bug | `IFSSO_kgDOBM-zmA` |
| … cosmetic | `IFSSO_kgDOBM-zmw` |
| … functional | `IFSSO_kgDOBM-zmQ` |
| `Route` | `IFSS_kgDOAsQ80g` |
| … Production Release | `IFSSO_kgDOBNeykw` |
| … Repository Change | `IFSSO_kgDOBNeylA` |
| … Other | `IFSSO_kgDOBNeylg` |
| `Priority` | `IFSS_kgDOAr9K2w` |
| … Urgent | `IFSSO_kgDOBM8AMw` |
| … High | `IFSSO_kgDOBM8ANA` |
| … Medium | `IFSSO_kgDOBM8ANQ` |
| … Low | `IFSSO_kgDOBM8ANg` |
| `Effort` | `IFSS_kgDOAr9K3g` |
| … High | `IFSSO_kgDOBM-0yw` |
| … Medium | `IFSSO_kgDOBM-0zA` |
| … Low | `IFSSO_kgDOBM-0zw` |
| `Stage` | `IFSS_kgDOAsC7CA` |
| … Triage | `IFSSO_kgDOBNJ-sg` |
| … Scope, Options and Dependencies | `IFSSO_kgDOBNJ-sw` |
| … On Hold | `IFSSO_kgDOBNQ6Fg` |
| … Ready for Project | `IFSSO_kgDOBNJ-tA` |
| … Candidate Project 1 | `IFSSO_kgDOBNJ9nA` |
| … Candidate Project 2 | `IFSSO_kgDOBNJ9nQ` |
| … Candidate Project 3 | `IFSSO_kgDOBNJ9ng` |
| `Phase` | `IFSS_kgDOAsBg2A` |
| … Scope | `IFSSO_kgDOBNDpUw` |
| … Q3 | `IFSSO_kgDOBNUxFg` |
| … Q2 | `IFSSO_kgDOBNUxFw` |
| … Q1 | `IFSSO_kgDOBNUxGA` |
| … Design and Test Approach | `IFSSO_kgDOBNUxGQ` |
| … Development | `IFSSO_kgDOBNDpVA` |
| … User testing | `IFSSO_kgDOBNDpVQ` |
| … Deployment | `IFSSO_kgDOBNDpVg` |
| … Post-deployment | `IFSSO_kgDOBNDpVw` |
| … Project Closedown | `IFSSO_kgDOBNU2qA` |

**To clear a field rather than set it**, the mutation is `deleteIssueFieldValue`
— not `clearIssueFieldValue`, which does not exist. Needed when converting a
requirement to a project: `Stage` is a requirement's journey and `Phase` is a
project's, so a converted issue carries a `Stage` that no longer means anything.

```bash
gh api graphql -f query='mutation($i:ID!){deleteIssueFieldValue(input:{issueId:$i,fieldId:"IFSS_kgDOAsC7CA"}){clientMutationId}}' -f i="$id"
```

**These ids are a cache and can go stale.** If one is rejected, re-read them:

```bash
gh api graphql -f query='{repository(owner:"delphside",name:"tile-lite-elite"){issueFields(first:30){nodes{... on IssueFieldSingleSelect{id name options{id name}}}}}}'
```

## Folding the requirements it takes

**Requirements only.** A `Project` absorbed into another follows the section below instead.

For each one: make it a sub-issue, label it `folded`, close it as completed with
a comment naming the project.

```bash
pid=$(gh api graphql -f query='{repository(owner:"delphside",name:"tile-lite-elite"){issue(number:'"$NUM"'){id}}}' -q '.data.repository.issue.id')
cid=$(gh api graphql -f query='{repository(owner:"delphside",name:"tile-lite-elite"){issue(number:NNN){id}}}' -q '.data.repository.issue.id')
gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' -f p="$pid" -f c="$cid"
gh issue edit NNN --add-label folded
gh issue close NNN --reason completed --comment "Folded into #$NUM, which owns this requirement from here."
```

`addSubIssue` takes `replaceParent:true` to move one that already has a parent.

## Moving requirements between projects

**`fold` is a requirement word and stays one.** A requirement is folded into the
project that takes it, once. Nothing else is folded.

**A requirement can move on afterwards**, from one project to another. Document
the move in **both** — the receiving project names the source (`#294 · #130`, so
the trail survives), the losing project records that it has gone and where.

**Move the sub-issue link with it**, using `replaceParent:true`. A folded
requirement is a sub-issue of the project that owns it, so leaving the link
behind puts the requirement under a project whose body no longer claims it —
which is where #130 and #151 sat until 2026-09-08, parented to #294 while #290
carried them as R5 and R6.

```bash
gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c,replaceParent:true}){issue{number}}}' -f p="$pid" -f c="$cid"
```

**A project whose requirements have all moved out can be closed.** It owns
nothing, so it has nothing left to do. Say in the comment which projects took
what, and pick whatever close reason fits — *duplicate* where it was genuinely
the same work seen twice, *not planned* otherwise. Owner, 2026-09-08: *"just
closing it because the requirements have moved to other named projects is
enough."*

**What must not happen to it**, both of which did to #294 on 2026-09-06:

| | why |
| --- | --- |
| `addSubIssue` on the project itself | **a `Project` sub-issue means a work package, and nothing else** — owner, 2026-09-08. It claims work still to come under that parent, with its own milestone and delivery. The title check reported #294 as a malformed package until the parent was removed. A `Requirement` sub-issue is a fold and is fine; a `Project` one is a structural claim |
| the `folded` label, and closing as **completed** | `folded` marks a requirement, and nothing was completed. #294's two requirements are unstarted today, and the wrong comment they exist to fix is still in `app.rs` |

## Afterwards

```bash
./scripts/check-transitions.sh          # has it done what its phase claims?
./scripts/roadmap-diagram.py --write    # regenerate docs/1.5
```

Commit the regenerated `docs/1.5` — the diagram is derived, so it should not sit
stale in the working tree.

## What goes wrong

**The wrong Phase option id.** `Deployment` and `Development` sit next to each
other and were confused once. Check the result rather than assuming it took.

**A milestone on a requirement.** Milestones hold project deliveries; a folded
requirement carries none.

**Editing on the wrong branch.** Documentation for a project belongs on `main`
unless the project has a branch, and committing to a branch you happen to be on
is a mistake made twice on 2026-09-02.
