# 427 Documentation by type: review brief

For an outside reviewer (GitHub Copilot or another agent), asked by the owner
to review #427's changes. Read [`AGENTS.md`](../../../../../AGENTS.md) first.
This file is how the reviewer and Claude talk to each other directly: Claude
writes each round's scope and questions, the reviewer writes its findings into
the round, and Claude writes a response under each. Earlier rounds stay as the
record.

## How to report

**Start from the latest `origin/main`.** Each round names the commits it
covers; if you do not have them, fetch first. A review of an older checkout
reports things already fixed.

Write your findings into the current round's **Findings** heading below, in a
pull request that changes this file and no other. Do not fix anything you find:
Claude merges the pull request, then answers each finding under **Response**
and makes the changes. The owner reads along and may comment on the pull
request.

- Number each finding.
- Give the file and line, what is wrong, and which standard it breaks.
- Suggest a fix when you have one.
- Say so when a question below has no finding. Silence reads as not checked.
- Separate what you verified against the code or the files from what you
  inferred.

The standards, in order of authority: [`CLAUDE.md`](../../../../../CLAUDE.md),
[`docs/3.9`](../../../../3.9-writing-documents.md) (what a document may hold),
[`docs/README.md`](../../../../README.md), and the `change-a-document` skill in
`.claude/skills/`.

## Round 1, 2026-09-27

Commits `da2cb96~1..07b1257`. Reviewed; the findings and Claude's response are
on #427, and were fixed in `302531f`.

## Round 2, 2026-09-27

Commits `07b1257..881ff9a`: the fixes from round 1, then changes made while the
owner read the result.

**What changed:**

1. The four numbered groups are now defined by scope, in the owner's words:
   1.x overviews, 2.x the end-to-end design of each functional area, 3.x the
   programme's organisation, processes and assets, 4.x reference. This replaced
   "one Diátaxis type per group". Changed in README, 3.9, CLAUDE.md, AGENTS.md
   and the change-a-document skill.
2. A new `docs/1.7-programme.md`: a one-page overview of how the programme is
   organised, meant as a signpost into 3.6 to 3.8.
3. 2.3 Engine Interface now describes the interface as built. Its benchmark
   material moved unchanged to a new `docs/2.8-engine-performance.md`.
4. Capacity Planning now owns performance and benchmarking (3.7).
5. 1.5's roadmap chart has a colour key and names each work package's parent
   (`scripts/board/roadmap.py`).
6. A reviewed report may have its references updated when their target moves
   (CLAUDE.md, 3.8).
7. The gaps in section 2 are raised as #428 (Functional design documents),
   including 2.2, which is still written as a plan.

**Questions:**

1. Are the new group definitions stated identically everywhere they appear,
   and does any numbered document now sit in the wrong group under them?
2. Is 1.7 brief enough to be a signpost, or does it duplicate 3.6 to 3.8? Is
   anything in it wrong against 3.6, 3.7 or CLAUDE.md?
3. Does 2.3 match `crates/engine-core/src/lib.rs` and
   `GameSession::maybe_run_engine_turn` in `crates/server-game/src/game_state.rs`?
   Check the facts, not just the prose.
4. Does 2.8 now read as one document, or does it still carry traces of being
   cut out of 2.3?
5. Is there anything left in section 1 or 2 that states an intention as if it
   were current, other than what #428 already lists?

**Not in scope:** the gaps #428 lists, and anything production-side, which
needs the owner's evidence.

**Result:** six findings, all verified and fixed in `6495521`; Q2 and Q4 had
none. Finding 4 was a code defect as well: the engine concurrency setting is
never applied, folded into #71 as #429. The findings and response are on #427,
from before this file carried them.

## Round 3, 2026-09-27

Commit `9b806ab`, and the round-2 fixes in `6495521` checked afresh.

**What changed:** the owner decided that benchmarking belongs to Capacity
Planning and the design that achieves the performance to section 2. So 2.8
Engine Performance keeps what the engine's search costs and where in a game
the work falls, and a new `docs/3.10-benchmarking.md` takes how the benchmark
is run and read, the machine difference and the raw measurements.
`scripts/document-map.py` now sorts numerically, so 3.10 follows 3.9.

**Questions:**

1. Is the line between 2.8 and 3.10 in the right place: is there design left in
   3.10, or measurement method left in 2.8?
2. Do 2.8 and 3.10 each read as one document, with no reference to something
   now in the other that is not a link?
3. Did round 2's fixes to 1.1, 2.4 and 4.2 introduce anything wrong against
   the code? 1.1's crate table, 2.4's account of what stays in memory, and
   4.2's migration table can each be checked against the files.
4. Is anything in section 2 or 4 still stated as intention, beyond #428's
   list? `doc-signals.py` does not catch "should", "suggested" or "not
   implemented".

### Findings

Copilot's review was done on its branch `427-review-round-3` (719a0f9), which
it could not push: its tools open a pull request only from the branch its task
began on. The owner relayed its summary, and Claude recorded it here.

- Q1 and Q2, the 2.8 and 3.10 split: no finding.
- Q3, round 2's fixes to 1.1, 2.4 and 4.2 checked against the code: no finding.
- Q4: `docs/2.1-rules-engine.md` still states intended design as current
  truth, beyond #428's list.

### Response

Q4, verified: 2.1 is written as a proposal ("Proposed Rust Shape", "Suggested
API Direction", a "Recommendation" section, "should" throughout), framed as
turning `first-try`'s model into a design. It is 2.2's pair, and both describe
`rules-shared`, so they are best rewritten together from the code. Added
to #428 (Functional design documents) rather than patched here.

**For the next round:** start it as a new Copilot task, so its branch is the
one its pull-request tool can publish.
