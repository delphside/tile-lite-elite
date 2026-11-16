# Tile Lite Elite

A multiplayer word-tile game — Rust end to end, playing at
[tileliteelite.com](https://tileliteelite.com).

The server owns every board, rack and rule; the two clients, a web client and a
desktop client, are thin presentation layers over one HTTP and WebSocket API.

## What it does

- **Play by turn or in one sitting**: games persist server-side, so a player
  can take a turn now or next week. The server takes a seat out of the game when it
  overruns its move time limit; on a limit longer than a day, a player gets an email
  reminder first.
- **Fill a table however you like**: the creator can claim a seat, invite a
  named player to it, open it to anyone signed in or email a join link to
  somebody with no account yet, and can reorder, add and remove seats until the
  game starts.
- **Five editions and four dictionaries**: the editions are listed in
  [4.4.4](docs/4.4.4-snapshot-json-schema.md#top-level-persistedgame)
  and the dictionaries in [4.3.5](docs/4.3.5-word-lists-and-dictionaries.md).
  Spanish's CH/LL/RR digraph tiles each occupy one square but display two
  letters. [`ATTRIBUTIONS.md`](ATTRIBUTIONS.md) records the word-list sources and
  licences.
- **Engines as first-class players**: an engine plugs in behind a `GameEngine`
  trait and its moves go through the same validation path as a human's.
- **Elo ratings and statistics**, per player and per engine, with a
  rating-over-time chart and per-game timings.
- **In-game chat**, unread markers and live updates over a WebSocket.

## Try it

To run it yourself, prepare the machine as
[4.3.1](docs/4.3.1-setup.md#development-environment) sets out, then, from the
clone:

```bash
./scripts/develop/services.sh start   # backend on :3000, web client on :8080
./scripts/develop/desktop.sh          # optional: a native desktop window against the same backend
```

Then open <http://127.0.0.1:8080>.
[4.3.2 Development](docs/4.3.2-development.md) covers the day-to-day loop.

## How it is put together

One rules crate runs the same legality and scoring code on the server and in
both clients, so a client scores every word as the server does. SQLite holds
everything, with a per-game JSON snapshot as the single source of truth and
denormalised tables alongside it for querying.

[4.1.1 Architecture](docs/4.1.1-architecture.md) has the full picture, including
deployment and the [crates](docs/4.1.1-architecture.md#crates), and
[4.1.3 Technology decisions](docs/4.1.3-technology-decisions.md) gives the reason
for each choice.

## Documentation

- [`docs/`](docs/README.md) is the index of this application's documents,
  numbered 4.1 to 4.4.
- The programme's documents are 1.x and 2.x in
  [`delphside/programme`](https://github.com/delphside/programme), and this
  application's records there are 3.1.x.

## Tests

How to run each suite is in
[4.3.7 §2](docs/4.3.7-how-testing-and-release-work.md#2-running-tests), and
what CI runs is in
[§3](docs/4.3.7-how-testing-and-release-work.md#3-continuous-integration). The
browser tests, which need a running environment, are in
[`e2e/README.md`](e2e/README.md).

## Status

A hobby project, in production and actively developed.
[4.1.4 Roadmap](docs/4.1.4-roadmap.md) tracks what is next.

## Licence

Dual-licensed, at your option, under either of:

- Apache License, Version 2.0 ([`LICENSE-APACHE`](LICENSE-APACHE))
- MIT License ([`LICENSE-MIT`](LICENSE-MIT))

This is the Rust ecosystem's usual pairing. Unless you explicitly state
otherwise, any contribution you intentionally submit for inclusion in this work
shall be dual-licensed as above, without any additional terms or conditions.
