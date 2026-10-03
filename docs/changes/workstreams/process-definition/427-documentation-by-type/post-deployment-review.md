# Post-deployment review: Documentation by type

Project: #427 · delivered to `main`, Repository Change, 2026-09-27 · reviewed:
2026-09-27, by Claude; the owner reviews it

- [ ] **owner** — read this review, then #427 moves to Project Closedown and
  closes

## 1. Was the intended scope delivered?

| in scope | delivered | note |
| --- | --- | --- |
| R1 the rule | yes, changed | began as one Diátaxis type per group; the owner replaced it with a definition by scope (1.x overviews, 2.x functional design, 3.x the programme, 4.x reference). Diátaxis now describes how parts are written. In README, 3.9, CLAUDE.md, AGENTS.md and the change-a-document skill |
| R2 the entry point | yes | README is a task index with the groups, their sections and links |
| R3 the pilot | yes | 2.5 to 2.7, 903 lines to 571 |
| R4 setup | yes | 3.1 is developer setup; host provisioning is in 3.4 |
| R5 the lifecycle | yes | 3.6, 3,029 lines to 1,549 |
| R6 reference | yes | 4.8, 478 lines to 161; its process material to 3.6 §2.15 |
| R7 the rest | yes | 3.3, 3.4, 3.7, 4.1, 4.2, 4.3, 1.1, 1.2, 1.3, 2.3, 2.4 and others |
| R8 the signal | yes | `doc-signals.py`, check-docs step 8: 170 lines to 0 |

**Added during the project, at the owner's direction:** 1.7 Programme; 2.3
split into the interface and 2.8 Engine Performance, with benchmarking moved to
a new 3.10 under Capacity Planning; a colour key and parent names on 1.5's
chart; the review brief as a channel with the outside reviewer; two rules in
CLAUDE.md (a reviewed report's references follow what they point to; whether
to do something is a Requirement, how is a Decision).

**Deferred:** section 2's gaps, and 2.1 and 2.2, which are still written as
plans, to #428. Six features the documents described as planned, to
Requirements #431 to #436. The unused engine concurrency setting, via #429,
to #71.

## 2. What happened that we did not plan for?

1. **Restructuring found more wrong facts than the outside review did.** 3.6
   described release queues retired weeks earlier; 3.7 gave validation to the
   wrong workstream; 4.8 contradicted one route per delivery; 4.1 said the app
   version is chosen by a retired lane; 4.2's migration list stopped short;
   several documents named retired scripts; 2.4 said games are never deleted.
2. **A documentation review found a code defect.** 2.3 said a setting bounds
   concurrent engine searches; nothing applies it (#429, folded into #71).
3. **The top-level definition changed after it was built.** R1 was settled in
   the outside review's terms and applied across five files, and the owner then
   replaced it on reading the result.
4. **The history count measured history but not intention.** It reached 0
   while 1.1, 2.1, 2.4 and 4.2 still described plans as current; the outside
   review found those.
5. **Relaying the outside review by pasting was slow**, and the first attempt
   at a direct channel failed: Copilot's tools publish only from the branch its
   task began on.
6. **A shell command ran document text.** Text written through a heredoc
   contained its own heredoc, ended early, and the shell ran some of it.
   Nothing was harmed.
7. **Easier than expected:** the rewrites rarely lost a rule. Removing history
   left most documents at half their length with nothing a reader needed gone.

## 3. Why — what was the cause?

1. Documents had been checked against each other, not against the code, and a
   changed rule was applied where it was noticed rather than wherever it was
   stated. Only the 4.x documents carry a freshness stamp, and 4.1, 4.2 and 4.3
   were last verified in July and August.
2. The document described the intention of the code comment beside
   `engine_limit`, not the code path.
3. The rule was taken from a reviewer's framing and not first read against the
   documents it would govern; 3.6 to 3.8 did not fit "how-to".
4. Dated history has textual markers; intention mostly uses words like
   "should" that also appear legitimately in rules.
5. Tool limits on Copilot's side, found by trying.
6. A shell heredoc cannot safely carry text that contains one.

## 4. What do we do next?

| finding | issue raised | or why not |
| --- | --- | --- |
| 1. stale facts; 4.x stamps months old | #437 (re-verify the reference documents) | |
| 1. section 2 written from plans | #428 | |
| 2. unused engine setting | #429, folded into #71 | |
| 3. rule settled before testing it | | no action: the owner's steer is the process working. The lesson is below |
| 4. the count misses intention | | no action: extending it to "should" would flag rules. The outside review is the check for intention, and the brief now asks for it |
| 5. relaying reviews | | done: the review brief is the channel, AGENTS.md points to it, and each round is a new Copilot task |
| 6. heredoc | | done: document text is written with the file tool; noted in W40's digest |

## 5. Areas to consider

- **Scope** grew mid-project, each addition at the owner's direction. It was
  recorded in commits and #427's comments, and is gathered in section 1 above.
- **Documentation**: every move repointed its links in the same commit, and
  the link check held them. A reference that is plain text, not a link, is not
  checked: two were found stale by hand.
- **Tooling**: `document-map.py` needed numeric sorting once 3.10 existed.
- **Time**: one day, mostly Claude alone as D54 allows; the owner's time went
  on decisions and reading, which is where it was meant to go.

## 6. Lessons worth keeping

**Verify a document against the code, not against another document.** Most
of what was wrong had agreed with its neighbours.

**Test a structural rule against the documents it governs before applying
it.** Reading 3.6 to 3.8 against "3.x is how-to" would have shown it did not
fit, before five files said it.
