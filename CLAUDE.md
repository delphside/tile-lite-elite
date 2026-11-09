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

- The application's own notes issue is #441.

## Changes

- [4.1.6](docs/4.1.6-document-map.md) is generated: after a rebase, run
  `./programme/scripts/docs/document-map.py --write` and commit it, stamped, if
  it changed.
- Every subject starts with this application's stamp, `app X.Y.Z api M.N:`, and
  a space.

## Deliveries and releases

- When `deploy.sh` warns that an issue that is not a project carries the
  milestone, the owner stops, then folds it into a work package or moves it out
  of the milestone before deploying
  ([4.3.3 §1.6](docs/4.3.3-testing-ci-and-release.md#16-ship-it)).
- Deploys build a fresh worktree at the target commit. The image goes Preview,
  then Rehearsal, then Production.
- After deploying, wait for CI on the version bump commit `deploy.sh` pushed,
  then run `scripts/deliver/verify.sh`
  ([4.3.3 §1.7](docs/4.3.3-testing-ci-and-release.md#17-verify-what-is-live)).
- **Dev leads production by one**: `deploy.sh` bumps `main`'s version to the
  next patch after a production deploy, and skips it in the cases
  [4.3.3 §2.4.2](docs/4.3.3-testing-ci-and-release.md#242-decide-whether-the-app-version-moves)
  lists.
- `Caddyfile`, `docker-compose.yml` and the `Dockerfile` are this
  application's own assets; changing one is a Production Release.
- Rehearsal is closed: `scripts/deliver/rehearsal-access.sh` grants access by
  QR code.
- The next structural release takes the major slot: `1.0.0`.
- The scripted production checks are `scripts/deliver/verify.sh`,
  `scripts/operate/check-hosts.sh` and the `/health` reads. Anything else
  against production (an admin CLI listing, a database query, a log dump) the
  owner runs.

## Where the detail is

| For | Read |
| --- | --- |
| what to type: release, rollback, emergency | [4.3.3](docs/4.3.3-testing-ci-and-release.md) |
| where a fact belongs, before writing it | [4.1.6](docs/4.1.6-document-map.md), and the change-a-document skill |
| the product's rules, which come to the owner in any workstream | [4.1.0](docs/4.1.0-rules.md) |
