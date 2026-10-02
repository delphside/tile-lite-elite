# 71 Tests: WP C, #270 Additional Game Lifecycle

Fitted to [`71-test-approach.md`](71-test-approach.md), which holds the layers
and what each can answer; this file says what WP C uses of them. The scope is
in [`71-design.md`](71-design.md), *Work packages*.

## What it proves

That what happens with nobody looking — RET-3's countdown, a message reaching a
player who is not looking — happens on its schedule and through the one
handler.

## Which layers it uses

- **Scripted test clients** with the scheduler driven by a test clock, so a
  job is proved to run without a request triggering it.

## The journeys and rules it covers

*Remove expired games* and *Remind the player on turn*, still to draw in
[`71-functional.md`](71-functional.md): RET-3, RET-4, TIME-4.

## Its acceptance

To be written when the package is scoped.
