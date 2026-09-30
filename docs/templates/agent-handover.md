<!-- markdownlint-disable-file MD041 -->
<!--
The handover Claude gives a subagent at launch, as its prompt (#441). The
agent's definition in .claude/agents/ holds what does not change between runs;
this holds what is particular to one job. The outside-review brief is the same
shape, kept in a file because it runs in rounds.

Fill every heading. Write "None" where one does not apply, so an empty heading
is never read as a forgotten one. Delete these comments.
-->

## Task

One sentence: the single thing to do. For a change, its kind: design, code,
documentation or tests.

## Done when

What finishes it, as checks the agent can run or read: the requirements it
meets, the tests that pass, the documents that say so. For a review, the
questions answered.

## Subject

The issue, document or branch, and the commit or stamp it runs from.

## Read as well

Anything beyond the agent's standing reading list. "None" if its list is
enough.

## Agreed but not yet written down

Decisions from Claude's conversation with the owner that the documents do not
show yet. The agent cannot see the conversation, so anything missing here is
invisible to it. If this heading is often long, decisions are reaching the
documents late.

## Questions

What specifically to answer, numbered.

## Out of scope

What to leave alone, so no effort goes there.
