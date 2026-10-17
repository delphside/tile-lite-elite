# Tile Lite Elite

A multiplayer word-tile game — Rust end to end, playing at
[tileliteelite.com](https://tileliteelite.com).

The server owns every board, rack and rule; the clients are thin
presentation layers over one HTTP + WebSocket API. Play in a browser or in a
native desktop window, against other people or against a bot, with games
that survive closing the tab and turns that can be taken days apart.

## What it does

- **Play-by-turn or in one sitting.** Games persist server-side, so a turn
  can be taken now or next week. Seats that overrun their move time limit
  are retired automatically, with an email reminder before that happens.
- **Fill a table however you like.** A seat can be claimed by you, invited
  to a named player, opened to anyone signed in, or emailed as a join link
  to somebody with no account yet. The creator can reorder, add and remove
  seats until the game starts.
- **Four editions and four dictionaries.** `official`, `north_american`,
  `german` and `spanish` board/tile rules; SOWPODS, ENABLE2K, German and
  Spanish word lists — including proper support for Spanish's CH/LL/RR
  digraph tiles, which occupy one square but display two letters. Word-list
  sources and licences are recorded in [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
- **Bots as first-class players.** Engines plug in behind a `GameEngine`
  trait and go through the same validation path as a human's move. They're
  rated on the same ladder as human players.
- **ELO ratings and stats**, per player and per engine, with a
  rating-over-time chart and per-game timings.
- **In-game chat**, unread markers, and live updates over a WebSocket.

## Try it

The quickest look is [tileliteelite.com](https://tileliteelite.com). To run
it yourself:

```bash
./scripts/develop/setup-dev-environment.sh   # Rust toolchain, wasm target, dx, sccache, Docker
./scripts/develop/services.sh start          # backend on :3000, web client on :8080
./scripts/develop/desktop.sh                 # optional: a native client against the same backend
```

Then open <http://127.0.0.1:8080>. [4.3.1 Setup](docs/4.3.1-setup.md) covers a
cold machine in full; [4.3.2 Development](docs/4.3.2-development.md) covers the
day-to-day loop.

## How it's put together

```text
crates/
  rules-shared   board, tiles, dictionaries, legality and scoring — no I/O
  engine-core    the GameEngine trait and the bundled greedy engine
  api            every wire type, shared verbatim by server and clients
  server-game    Axum server: game state, persistence, auth, admin endpoints
  ui             Dioxus client, compiled to both WASM (web) and native (desktop)
  admin-cli      operator tooling, loopback-only, against the server's /admin/*
```

One rules crate means the same legality and scoring code runs on the server
and in both clients — the server stays authoritative, but a client never
disagrees with it about what a word scores. SQLite holds everything, with a
per-game JSON snapshot as the single source of truth and denormalized
tables alongside it for querying. Deployment is Docker Compose behind Caddy
on a free-tier Oracle Cloud VM.

[4.1.1 Architecture](docs/4.1.1-architecture.md) has the full picture and
[4.1.3 Technology Decisions](docs/4.1.3-technology-decisions.md) explains why
each piece was chosen.

## Documentation

[`docs/`](docs/README.md) is the index. This application's documents are
4.1 to 4.4: **4.1** overview and architecture, **4.2** design and domain,
**4.3** development and operation (setup → development → testing and release →
production), and **4.4** reference (configuration, database schema, API schema,
data dictionary). The programme's documents are 1.x and 2.x in
[`delphside/programme`](https://github.com/delphside/programme), and this
application's records there are 3.1.x. Start at
[4.1.1 Architecture](docs/4.1.1-architecture.md) to understand the system, or
[4.3.1 Setup](docs/4.3.1-setup.md) to get it running.

## Tests

```bash
cargo test --workspace     # unit, integration and HTTP-level tests
cd e2e && npm test         # Playwright, drives the real client in a browser
```

CI runs format, clippy (warnings denied), the test suite, and a wasm build
on every push, plus the end-to-end suite against a real preview Docker stack
on pull requests and pushes to `main`. See
[4.3.3 Testing, CI & Release](docs/4.3.3-testing-ci-and-release.md).

## Status

A hobby project, in production and actively developed. The core game,
accounts, invitations, ratings, chat and both clients are built and live;
[4.1.4 Roadmap](docs/4.1.4-roadmap.md) tracks what's next.

## Licence

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT licence ([LICENSE-MIT](LICENSE-MIT))

at your option — the Rust ecosystem's usual pairing. Unless you explicitly
state otherwise, any contribution you intentionally submit for inclusion in
this work shall be dual-licensed as above, without any additional terms or
conditions.
