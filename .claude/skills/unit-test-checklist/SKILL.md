---
name: unit-test-checklist
description: A nudge to run through RIGHT-BICEP/CORRECT before calling a change's unit tests done. Use whenever writing or reviewing unit tests for new or changed logic — not for Technical (Rehearsal) or Functional user (Preview) tests, which are a different question answered in docs/3.3.
---

# Unit test checklist

**The checklist itself lives in one place**: `docs/3.3-testing-ci-and-release.md`, under
"Unit Test Coverage Checklist" (search for that heading — it sits inside the
section on the third Test approach heading, `### Unit tests`). Read it there
rather than trusting a copy here, so a later edit to the checklist cannot
drift from what this skill tells you to do.

## When this fires

Before treating a change's unit tests as sufficient — while writing them, or
while reviewing someone else's. Not at the point of filling in a project
issue's `### Unit tests` heading, which owes a short list of the scenarios
covered (docs/3.3 says how), not every RIGHT-BICEP letter spelled out.

## How to use it

Read the checklist, then go through each letter against the actual code
being tested:

- Does it apply here at all? Most letters won't, for most changes — a data
  model has no performance characteristic worth a test, most functions have
  no inverse. Skipping a letter because it does not apply is the checklist
  working, not a gap.
- Where it does apply, is there a test for it? If not, that is a missing
  test, not a missing mention — `docs/3.3`'s own rule: not listed in an
  issue is not the same as not tested.

The checklist is a nudge to think about each category, never a requirement
that every letter produces a test.
