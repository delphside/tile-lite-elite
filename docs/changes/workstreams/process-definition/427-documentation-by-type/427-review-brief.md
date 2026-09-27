# 427 Documentation by type: review brief

For an outside reviewer (GitHub Copilot or another agent), asked by the owner
to review #427's changes. Read [`AGENTS.md`](../../../../../AGENTS.md) first.
This brief says what to review and how to report. Each round is added below;
earlier rounds stay as the record.

## How to report

Reply in the conversation, not by changing files. The owner passes the report
to Claude, who records it on #427 and acts on it.

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
never applied, folded into #71 as #429. The response is on #427.
