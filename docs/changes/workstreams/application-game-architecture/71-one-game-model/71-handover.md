# 71 Handover

**What a thread taking over #71 needs, and where it lives.** The role is the
design authority for Application & Game Architecture, which runs #71
because #71 dominates the workstream ([5.7](../../../../5.7-roles-and-responsibilities.md)).
This file says where the state is and what is open; the state itself is in the
documents and issues it names. Written 2026-10-14, at the handover after the
decision backlog was cleared.

## Read first

1. #71's body: the allocation table, the Decisions table, and the code-review
   findings routed from #460.
2. [`71-design.md`](71-design.md): the *Pending decisions* table at the top,
   then the work-package sections.
3. [`71-delivery.md`](71-delivery.md): `release/1.0.0` for #268 and #269.
4. [`71-functional.md`](71-functional.md): the use case, the journeys, the
   lifecycles, and *Questions the journeys raise*.
5. D72 (#479) and `docs/1.0` *Invitations by address* on PR #471.

## Where state lives

- **This folder** is a change document. It reaches `main` through a short-lived
  `claude/` branch with one pull request, merged by the thread once the
  required checks pass, with a *Review* section saying none is needed (owner,
  2026-10-14). The pre-commit hook refuses `docs/changes/` on a branch, so these
  commits use `--no-verify` and say why.
- **Living documents** (`docs/1.0` and the numbered documents) change on the
  project branch, PR #471 for now, which the owner reviews.
- **Decisions** are issues D56 to D72 (#442 to #479), applied in the documents
  and closed once applied.
- **Single writer.** This thread writes this folder, #71's body and the D-issues
  above. Other threads, the local WSL sessions included, send changes through
  the coordinator.

## Open, and whose move it is

| item | waits on |
| --- | --- |
| the fifteen functional questions in `71-functional.md`, *Questions the journeys raise*; 1 to 3 are on decision cards in the thread | owner |
| *functional before technical* as a docs/5.1 rule (owner agreed 2026-10-14): applied by the programme authority thread; then 71-design.md's *Pending decisions* links to it | programme authority, then Claude |
| #406's four diagram-format questions, and #428 | owner |
| DEL-2 refusing to close an account while a passed invitation names it: principle 9 calls it acceptable | owner, on #439 |
| #439's open rows: registering a held address reveals it is held; recovery answering the same; a password to change an address; sign-in by name or address | owner, on #439 |
| WP C's schema, which waits on how #87 reaches a player who is not looking (Web Push or not), and whether RET-3's question is sent; settle before #268's migration is written (D64) | owner |

## A tooling defect met on the way

`scripts/programme/board/roadmap-diagram.py --project 71 --write-issue 71`
reads issues with `gh issue view`, which is GraphQL and refused in cloud
sessions, so it finds no body. Its row pattern also matches the Decisions
table, drawing two false packages. On 2026-10-14 the diagram in #71's body was
regenerated through a REST shim with those two removed by hand.
