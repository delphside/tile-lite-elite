# Tile Lite Elite: the rules that are its own

@programme/CLAUDE.md

## Where the programme lives

- The generic rules, skills and agents are in the `programme/` submodule
  (`delphside/programme`), pinned at a commit of this repository's choosing.
  `.claude/skills` and `.claude/agents` link into it. Run
  `git submodule update --init` after a clone or a pull that moves the pin.
- **The `docs/1.x`, `records/` and `applications/` paths in the imported rules
  are the programme repository's.** `docs/1.x` (the generic rules) are read in
  `programme/`. `records/` and `applications/` paths are read **and** changed in
  the live checkout (`board-records.py live`), never the submodule.
- The live checkout is beside this repository's main worktree at `../programme`
  or wherever `PROGRAMME_DIR` says. Records and change documents are changed
  there, on its `main`; a cloud session does it by a short-lived pull request.
  The pinned `programme/` is read-only: never change it from here.
- An issue in another repository is written `owner/repo#N`, such as
  `delphside/programme#N` or `delphside/tile-lite-elite#N`.

## The session on the web

- The application's own notes issue is #643 *Notes for the local session*.

## Changes

- [4.1.6](docs/4.1.6-document-map.md) is generated: after a rebase, run
  `./programme/scripts/docs/document-map.py --write` and commit it, stamped, if
  it changed.
- Every subject starts with this application's stamp, `app X.Y.Z api M.N:`, and
  a space.

## Deliveries and releases

- A deploy is `turpin deploy ENV REF`. `turpin build SHA` builds a commit once,
  and each environment pulls that build by digest: Preview, then Rehearsal,
  then the release step (`turpin release`, run in the `main` worktree), then
  Production. What to type is
  [4.3.3](docs/4.3.3-testing-ci-and-release.md); what each command checks is
  [1.2](https://github.com/delphside/programme/blob/main/docs/1.2-change-lifecycle.md#making-a-release-then-deploying-it).
- After `turpin release`, wait for CI on the bump commit it pushed. After a
  production deploy, run `scripts/deliver/verify.sh`
  ([4.3.3 §1.7](docs/4.3.3-testing-ci-and-release.md#17-verify-what-is-live)).
- **`main`'s versions are provisional until a release fixes them** (owner,
  2026-11-16): `turpin release` bumps the app version to the next patch, and
  later changes may move it
  ([4.3.7 §4.2](docs/4.3.7-how-testing-and-release-work.md#42-decide-whether-the-app-version-moves)).
- When `turpin release` asks about an issue in the milestone that no commit
  names (`Confirm that #N is in this build [y/N]`), and the issue is not a
  project, the owner decides: fold it into a work package, move it out of the
  milestone, or ship it in the milestone
  ([4.3.7 §5.6](docs/4.3.7-how-testing-and-release-work.md#56-where-a-gate-meets-a-limit)).
  `--confirm N` answers ahead, and `--set-aside milestone REASON` carries the
  milestone as it stands.
- Changing an artefact that reaches the image, the `Caddyfile`,
  `docker-compose.yml`, `Dockerfile`, the hooks in `turpin/hooks/` and the
  host files' sources among them, is a Production Release;
  [3.1.2](https://github.com/delphside/programme/blob/main/applications/tile-lite-elite/3.1.2-artefacts.md)
  lists them.
- Rehearsal is closed: `scripts/deliver/rehearsal-access.sh` grants access by
  QR code.
- The next structural release takes the major slot: `1.0.0`.
- The scripted production checks are `scripts/deliver/verify.sh`,
  `scripts/operate/check-hosts.sh` (the programme's `board-hosts.py`, which the
  `host-currency` activity also runs), `turpin status ENV` with Turpin's reads
  of production's state, and the `/health` reads. Rehearsal's access is
  closed, so `scripts/deliver/seed-rehearsal.sh` falls under the programme's
  rule on copying production's data.

## Where the detail is

| For | Read |
| --- | --- |
| what to type: a release | [4.3.3](docs/4.3.3-testing-ci-and-release.md) |
| a rollback, an emergency, a failing step | [4.3.6](docs/4.3.6-when-a-release-goes-wrong.md) |
| where a fact belongs, before writing it | [4.1.6](docs/4.1.6-document-map.md), and the change-a-document skill |
| the product's rules, which come to the owner in any workstream | [4.1.0](docs/4.1.0-rules.md) |
