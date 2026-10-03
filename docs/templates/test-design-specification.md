# Test design specification: *change*

<!--
Delete these comments as you go.

Copy it into the project's folder, named for the project number —
  e.g. 174-test-design.md — before completing it.

Guide to completion:  `docs/3.3`'s "How a test design specification is built"

Each of these ten parts is required.  Together they ensure the tests have good
coverage.  

Worked examples:

  docs/changes/41-user-deletion-test-design.md   functional, user-testable
  docs/changes/25-rate-limiting-test-design.md   non-functional, judged by a
                                               script on the rehearsal host

These are at the level of Project, if there is one, otherwise issue.

This is NOT a test plan in the standards' sense — that is a management document
of scope, schedule and resources, which we do not write.  See docs/3.3 §2.4.2.
-->

Issue: #N · type: `label` · release: `patch alone` / `minor` / `major`
<!-- or 
Project: #N · type: `label` · release: `patch alone` / `minor` / `major`
-->

## 1. Rules

<!-- Intent, before anything derives from it. Written from what the system is
supposed to do — docs/1.0-rules.md, the issue, the design note — not from the
code, or the plan inherits the code's mistakes. Number them; everything below
refers back. -->

| | rule |
| --- | --- |
| R1 | |
| R2 | |

## 2. Conditions, grouped into dimensions

<!-- Each dimension is one axis the behaviour varies along. Mark a dimension
**complete** where its values exhaust the possibilities, so a reader can see
which are and are not. -->

**D1 — *name*** (complete / not complete)

- |
- |

## 3. Outcomes

<!-- Separately from conditions, and each phrased as something observable. "The
request is refused with 400 and the body names the seat" — not "it works". If
you cannot see it, a test cannot assert it. -->

| | outcome |
| --- | --- |
| O1 | |

## 4. Matrix

<!-- Where two dimensions cross, a table with a symbol for combinations that
cannot occur, so impossible is distinguishable from untested. -->

## 5. Scenarios

<!-- Lifecycle walks, each covering several conditions. Number them for
navigation while writing; the tests they produce are named for behaviour. -->

| | scenario | conditions | outcomes |
| --- | --- | --- | --- |
| S1 | | | |

## 6. Refusals and successes

<!-- Every refusal followed by a success. A test that only watches something be
refused passes against a system that refuses everything. -->

## 7. Coverage, both ways

<!-- Every rule to a scenario, and every scenario to a rule. Both directions:
one finds untested rules, the other finds scenarios testing nothing. -->

| rule | scenarios |
| --- | --- |
| R1 | |

| scenario | rules |
| --- | --- |
| S1 | |

## 8. Approach

<!-- What runs and where: unit, integration, e2e, or a script on rehearsal.
What is real and what is stubbed. How time is manipulated. What state each test
starts from. -->

## 9. Test names

<!-- Named for the behaviour, never for a scenario number.
`delete_refused_while_a_game_is_waiting`, not `s1`. Six months later a failing
`s1` sends the reader to a document to find out what broke. -->

## 10. Gaps

<!-- Each saying what would make the test fail if the gap matters. A gap written
down is a decision with a name on it; a gap left out is indistinguishable from
coverage. -->

| gap | what it would take to close it | why it is acceptable for now |
| --- | --- | --- |
| | | |
