<!-- markdownlint-disable-file MD041 -->
<!--
Copy to the project's folder as `post-deployment-review.md` and fill it in.

**Claude writes it; Steve reviews it.** That order matters: the person who did
the work is worst placed to notice what it cost, and best placed to remember
what happened.

**When:** once the project's last release is live and has been used — not on
the day it ships. A week is usually enough for the interesting failures to
surface, and #67 is why: it was closed by a milestone, listed as deferred in the
testing report, and genuinely broken.

The shape follows the **After Action Review**, whose four questions are the
oldest and clearest form of this: what did we set out to do, what happened, why
the difference, what do we do next. PRINCE2's Lessons Report adds the part the
AAR leaves out — that a lesson is only worth capturing if somebody can act on
it, which is why every finding here ends as an issue or is explicitly dropped.

Delete these comments as you go.
-->

# Post-deployment review: *project*

Project: #N · releases: `X.Y.Z` … · reviewed: *date*

## 1. Was the intended scope delivered?

The scope as the project issue fixed it, against what is live. Not a summary of
the work — a comparison, item by item, with anything dropped or deferred named
as such.

| in scope | delivered | note |
| --- | --- | --- |
| | | |

**Anything deferred:** where did it go — a new issue, a later project, or
nowhere? "Nowhere" is a legitimate answer and the one worth recording.

## 2. What happened that we did not plan for?

Surprises, in both directions. A thing that turned out easier belongs here as
much as a thing that broke.

## 3. Why — what was the cause?

For each surprise: the mechanism, not the blame. Prefer *"the check ran only
when someone looked"* to *"we forgot to check"*.

## 4. What do we do next?

Every finding is an action or a deliberate non-action. An observation with
neither is a note nobody will read again.

| finding | issue raised | or why not |
| --- | --- | --- |
| | | |

## 5. Areas to consider

Prompts, not a checklist to tick — most will not apply. They are here because
each has cost us something before.

- **Scope** — did it change mid-project, and was the change recorded where the
  scope was fixed?
- **The milestone** — did anything close that had not shipped? `deploy.sh`
  closes every open issue in a milestone (#67)
- **Testing** — was anything marked deferred and then released anyway? Did the
  tests derive from the rules, or from the code they were testing?
- **Documentation** — is any numbered document now wrong? Did a rule end up in
  two places?
- **The deploy itself** — gates skipped, a rollback needed, a migration that
  wanted more care than it got
- **Environments** — did preview and rehearsal hold what production got?
- **Data** — anything irreversible: deletions, migrations, retention
- **Tooling** — did a script do something surprising, or fail silently? Did a
  tool read its own documentation (twice, 2026-08-20)
- **Time** — where did it actually go, against where it was expected to
- **The process** — which rule helped, which was in the way, and which was
  quietly ignored? A rule ignored twice is a defect in the rule

## 6. Lessons worth keeping

The one or two sentences a future project would want. If there are none, say
so — a review with nothing to say is a good outcome, and pretending otherwise
teaches nobody anything.
