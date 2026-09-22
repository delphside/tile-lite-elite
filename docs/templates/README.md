# Templates

Documents you copy and fill in, rather than write from a blank page.

A template says **what must be included**; the worked examples beside it show
**how to complete it**. Both matter — a template alone leaves you guessing at
depth, and an example alone leaves you guessing at what was optional.

| template | copy it to | worked examples |
| --- | --- | --- |
| [test-design-specification.md](test-design-specification.md) | the project's folder — `docs/changes/projects/<name>/` — else the issue's | [user deletion](../changes/41-user-deletion-test-design.md) (#41, functional) · [rate limiting](../changes/25-rate-limiting-test-design.md) (#25, non-functional) |
| [post-deployment-review.md](post-deployment-review.md) | the project's folder, once its last release has been live and used | none yet — the first project to finish writes it |
| [capacity-plan.md](capacity-plan.md) | `docs/reports/capacity_plan/<YYYY-MM>.md`, monthly | [September 2026](../reports/capacity_plan/2026-09.md) (#291 R1, the first) |

## The other half, and why it is not here

**Templates for what you raise live in `.github/`, because GitHub requires it.**
An issue form is only offered to you if it sits in `.github/ISSUE_TEMPLATE/`, and
a pull request body is only pre-filled from `.github/PULL_REQUEST_TEMPLATE.md`.
Neither can be moved.

| template | offered when |
| --- | --- |
| [`Requirement`](../../.github/ISSUE_TEMPLATE/requirement.yml) · [`Project`](../../.github/ISSUE_TEMPLATE/project.yml) · [`Decision`](../../.github/ISSUE_TEMPLATE/decision.yml) | raising an issue of that type |
| [`PULL_REQUEST_TEMPLATE.md`](../../.github/PULL_REQUEST_TEMPLATE.md) | opening a pull request |

**So the split is by who fills it in, not by what it is.** GitHub fills those
four in front of you; these ones you copy into the repository yourself. Listed
here because somebody looking for *the templates* should find all of them from
one place, whichever half they land on first.

## Notes

**Why a template rather than the prose that describes it.** `docs/3.3`'s "How a
test design specification is built" explains the ten parts and why each earns its place. That is
the right document to read once; it is the wrong thing to work from every time,
because turning a description into a document is work repeated at every use, and
the part you forget is invisible.

**Keep the reasoning out of the template.** The template carries what to write
and nothing else, with pointers to where the reasoning lives. A template that
argues with you while you fill it in is one people stop opening.

**A report's template is the same idea with a different lifetime.** A test design
specification is written once for a project; a capacity plan is written every
month for ever, and the thing a template protects against is different in each
case. For the specification it is forgetting a part. For the report it is the
shape drifting between months, which destroys the only property that makes a
series worth keeping — that the rows are comparable.

**Two examples, deliberately unalike.** The user-deletion specification is functional and
user-testable; rate limiting has nothing for a person to look at, so its
judgement moved into a script on the rehearsal host. A single example teaches its
own shape as though it were the rule.
