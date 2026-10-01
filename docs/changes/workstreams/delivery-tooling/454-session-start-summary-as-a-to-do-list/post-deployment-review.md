<!-- markdownlint-disable-file MD041 -->
# Post-deployment review: the session-start summary as a to-do list for Claude

Project: #454, one delivery · straight to `main`, no milestone · reviewed: 2026-10-01 (closed 2026-10-01 on the owner's instruction)

## 1. Was the intended scope delivered?

| in scope | delivered | note |
| --- | --- | --- |
| R1 a comment is listed only until Claude has dealt with it on that issue | yes, for a comment | #441's test note was listed, Claude answered it, and it was not listed again. An answer made any other way is not recognised, see section 2 |
| R2 each listed comment shows its first line | yes | seen at the 2026-10-01 session start, each cut at 120 characters |
| R3 each section says whose move it is | yes | seen at the same session start |
| R4 the summary stays inside the hook's limits | yes | the log shows a start and an end for each session, served from cache in under a second |
| R5 a check before commenting shows what is open on that issue | yes | `.claude/comment-check.sh`; commenting on #441 showed its open note first |

All of it went to `main` in 7788dee. The owner started a session afterwards and the summary was as designed.

## 2. What happened that we did not plan for?

The summary listed the owner's answers to five decisions (#442 to #446) and to #421's questions, though each had been dealt with. The owner had answered in a comment, Claude had recorded the answer in the issue's body, and the Decision State field moved. The rule only counts a later comment from Claude, so all six stayed listed. Applying the five decisions did not clear them either, and a Claude comment on each is what would.

The first unlimited run listed 137 issues, most of them closed or merged. Restricting the list to open issues and pull requests was settled before the build.

## 3. Why?

The rule treats a comment as the only way Claude answers. In this project it is not: a decision is answered by a body edit and a field move, and a comment is only one of the three. The test written for it covered a deploy note after a question, but not a body edit.

## 4. What do we do next?

| finding | issue raised | or why not |
| --- | --- | --- |
| an answer made by a body edit or a Decision State move is not seen as dealing with a comment | not raised | the owner decides: either Claude comments on each issue it answers, which is cheap and needs no change, or the rule learns that a body edit after the comment counts. The first is in use |
| R5's check reports and never blocks, so it can be ignored | none | deliberate, because the comment may be the answer |

## 5. Areas to consider

- Scope: unchanged.
- Documentation: docs/5.0's row for the hook describes the rule and the check.
- Tooling: the summary is capped at 12 comments with a count of the earlier ones, and was not close to the cap at this session start.

## 6. Lessons worth keeping

A list of what is unanswered is only as good as its definition of answered. Check that definition against every way the work is actually answered, not only the one the design assumed.
