<!-- markdownlint-disable-file MD041 -->
<!--
The body is the review surface. Say what is being asked for; the argument, the
measurements and the design live on the issue. The rules for the body are in
*Changes* in
[the programme's `CLAUDE.md`](https://github.com/delphside/programme/blob/main/CLAUDE.md#changes).

Who reviews, and when Claude merges, is
[1.2 §2.2](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md#22-when-to-branch-and-what-pre-approved-means).
Where the change owes the owner's review, add him as reviewer at creation and
ask for it in the chat; where it does not, replace the boxes under *Review*
with `No review owed:` and the reason.

Replace `N` on the `Refs #N` line with the project or work package this
delivers, or write `Activity: <id>`, and `Initiative: <id>` where there is
one, for a change that serves an activity.
`Closes #N` is never used: no merge closes an issue.

*Review rounds* is the review record, in the form
[1.1](https://github.com/delphside/programme/blob/main/docs/1.1-programme-tooling.md#claudes-tooling)
gives. Keep `None owed:` where 1.1's *what owes none* row covers the change;
otherwise replace it with the record.
-->

Refs #N

## What is being requested

<!--
Which part of the project's scope this delivers, or the scope of the activity
where there is no project. Named against it, so a reviewer can tell what is now
done from what is still owed.
-->

## What is deliberately left out

<!--
Scope this pull request does not carry, and why — a later delivery, a
dependency not ready, a decision still open. "Nothing" is a valid answer, and a
blank heading is not.
-->

## Review

**Write anything you want changed underneath its item**, as an indented `>` note, and tick what is settled.

- [ ] **owner** — the change does what the issue or activity asks
  >
- [ ] **owner** — what is left out is deliberate, and named in *What is deliberately left out*
  >

### Any other comments

Anything that does not belong under an item — including "this is fine", and including what nobody thought to ask about.

>

## Review rounds

None owed:
