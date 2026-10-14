# 71 Tests: WP F, #290 dioxus 0.7

Fitted to [`71-test-approach.md`](71-test-approach.md), which holds the layers
and what each can answer; this file says what WP F uses of them. The scope is
in [`71-design.md`](71-design.md), *Work packages*.

## What it proves

That the client behaves the same on dioxus 0.7, so a later client defect is not
the upgrade's.

## Which layers it uses

- **Playwright**: the existing e2e suite, unchanged, against Preview.

## The journeys and rules it covers

Every journey the e2e suite already walks; no new ones.

## Its acceptance

The four requirements and checks on #290 itself.
