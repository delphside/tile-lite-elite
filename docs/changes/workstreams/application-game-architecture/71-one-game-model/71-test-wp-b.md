# 71 Tests: WP B, #269 Core Client UI

Fitted to [`71-test-approach.md`](71-test-approach.md), which holds the layers
and what each can answer; this file says what WP B uses of them. The scope is
in [`71-design.md`](71-design.md), *Work packages*.

## What it proves

The client half: one writer of the server cache, and a composition that
survives what it should and nothing else.

## Which layers it uses

- **Pure function tests** for `should_apply`, `current_key` and
  `live_composition`, each a table of inputs and expected answers.
- **Playwright**, kept small: `e2e/tests/ui-state.spec.ts` and the wiring
  between the panes.

## The journeys and rules it covers

*Take a turn*, the composing step, and *Abort a game*, from
[`71-functional.md`](71-functional.md).

## Its acceptance

- [ ] **Claude** — the two `test.fixme` cases in `e2e/tests/ui-state.spec.ts` are turned on and pass (D57, #443)
- [ ] **Claude** — a word staged while waiting survives an opponent's pass and chat, and is discarded when a tile lands in its cells
- [ ] **owner** — on Preview, a move made in one tab shows in another without a refresh, and the panes agree
