<!-- markdownlint-disable-file MD041 -->
# Post-deployment review: Claude sessions from the workspace root

Project: #452, with #453 as delivery 2 · milestone `0.9.0b` · reviewed: 2026-10-01 (draft for the owner)

## 1. Was the intended scope delivered?

| in scope | delivered | note |
| --- | --- | --- |
| R1 a session in VS Code loads `CLAUDE.md`, the skills, the agents and the hooks | yes | by opening `~/tile-lite-elite/main`, not by any file at the root. The owner started a session there and it loaded all of them, and the hook ran |
| R2 docs/3.2 says which folder to open | yes | 0e57db0 |
| R3 the session-start hook finishes inside its timeout | yes | 30s to 90s in `.claude/settings.json`, 0e57db0. It measured 40s |

Deferred: making the hook faster. `board-inbox.py` alone takes 25s. Dropped, because nothing needs it yet and the tooling rule is to change when something first needs it.

## 2. What happened that we did not plan for?

The project was meant to be about files at the workspace root. It became a one line instruction, because opening the right folder fixed what the files only worked around. That is the cheapest outcome and it came from the owner, not from the first design.

The delivery classification went wrong twice.

1. The first body put docs/3.2 under Programme Tooling and Docs. `board-documents.py` says it is an application document, so the change spans two routes.
2. The two routes were then recorded as one commit, 0e57db0, straight to `main`. Splitting them afterwards meant a work package (#453), a letter milestone (0.9.0b) and a delivery-log row recorded after the fact, with no branch, by the owner's decision.

The rules were then corrected. The "rules serve the project" rule went into `CLAUDE.md`, and the sub-project rule was rewritten twice to cover any number of deliveries.

Work package #453 turned out to be unnecessary. By the rule as now written, the parent carries the only milestone because it is on the last delivery.

## 3. Why?

- The route question was never asked at triage. A route is a property of each artefact and nothing prompted for the artefact list until `board-check.py` asked for a Route on the parent.
- D53 reasoned from a phase that cannot be doubled and never considered the order of deliveries, so it demanded a sub-project where the order made it harmless. Two cases (#452 and the owner's memory of the original rule) exposed it.
- Nothing in the documents said the owner may set a rule aside, so the process read as binding.

## 4. What do we do next?

| finding | issue raised | or why not |
| --- | --- | --- |
| the sub-project rule did not cover many deliveries or their order | none | fixed in 8babc80 in docs/5.1 and `CLAUDE.md` |
| the owner's authority to set rules aside was unwritten | none | fixed in e3c7753 |
| route classification is not checked against the artefact list when a project is raised | not raised | a project with one delivery spanning two routes is rare and `board-check.py` found it. Raise it if it happens again |
| per delivery information: it is unsettled whether a no-milestone delivery with its own post-deployment checks must have a sub-project | not raised | the owner recalls a discussion and could not place it. The rule says optional until he recalls it |
| docs/5.1 had a link labelled `[3.0]` pointing at `5.0-programme-tooling.md` | none | fixed in the commit that adds this review |
| hook runs 25s in `board-inbox.py` | not raised | see section 1 |

## 5. Areas to consider

- Scope: it did not change, but the design changed from files at the root to opening one folder.
- The milestone: 0.9.0b closes by hand. Nothing else is in it.
- Documentation: `CLAUDE.md` and docs/5.1 changed in two steps, and the second replaced the first's wording. They agree now.
- Tooling: the hook's timeout was a silent failure, with nothing shown, and that is why the first sessions looked as if the inbox did not exist.
- The process: the rules were set aside once (no branch for the 3.2 change, by decision) and the second rule that proved too heavy was D53. Two rules in one project, both corrected.

## 6. Lessons worth keeping

Ask which route each artefact takes before choosing the delivery shape. A silent hook failure looks like a missing feature, so check a timeout before suspecting the hook's contents.
