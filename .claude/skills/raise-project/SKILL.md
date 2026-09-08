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

Every project body carries these, each holding the content or a link to the
document that holds it, never both:

```markdown
## Requirements
| | from | |
| --- | --- | --- |
| R1 | #nnn | what must be true when this is done |

## Design

## Impacted artefacts
| artefact | new or modified | route |
| --- | --- | --- |

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

**Every delivery is a sub-project** (D51) — a `Project` whose parent is this
one, carrying its own milestone, artefacts, test approach and post-deployment
checks. The parent owns the requirements, the design and the documents, carries
no milestone, and lists its deliveries: each row names a sub-project or says
`pre-approved`. A pre-approved delivery has no issue and no milestone, and its
runbook sits under that list.

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
