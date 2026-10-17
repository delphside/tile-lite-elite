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
- The records and change documents are in `delphside/programme` too, but its
  live checkout, beside this repository's main worktree at `../programme` or
  wherever `PROGRAMME_DIR` says. They are changed there, on its `main`; a cloud
  session does it by a short-lived pull request. The pinned `programme/` is
  read-only: never change it from here.
- A reference to an issue in the other repository is written
  `delphside/programme#N` or `delphside/tile-lite-elite#N`.

## The work

- Anything reaching production, the product and game rules, and anything
  irreversible outside git come to the owner whatever their workstream.

## The session on the web

- The application's own notes issue, where a web session leaves its note for
  the local session when no issue concerns the work, is #441.

## Changes

- `docs/4.1.6` is generated and is regenerated on the branch after its rebase.
- Every subject starts with this application's stamp, `app X.Y.Z api M.N:`, and
  a space.

## Deliveries and releases

- `deploy.sh` warns when a requirement carries a milestone, and it was right
  when #380 and #379 were put in 0.8.1 on 2026-09-19 and shipped through the
  warning.
- Deploys build a fresh worktree at the target commit, never the working
  tree. The image goes Preview, then Rehearsal, then Production.
- After deploying, run verify.sh.
- **Dev leads production by one**: bump dev to the next patch straight after
  each production deploy.
- `Caddyfile`, `docker-compose.yml` and the `Dockerfile` are this
  application's own assets; changing one is a Production Release.
- Rehearsal is closed. scripts/deliver/rehearsal-access.sh grants access by QR code.
- **Production access is the owner's to run**, reads included: an admin CLI
  listing, a database query, a log dump. The scripted checks the tooling
  already makes, which are bounded and reviewed, are `verify.sh`,
  `check-hosts.sh` and the `/health` reads.

## Tests, checks and decisions

- The game rules are docs/4.1.0.

## Where the detail is

| for | read |
| --- | --- |
| what to type: release, rollback, emergency | docs/4.3.3 |
| where a fact belongs, before writing it | docs/4.1.6, and the change-a-document skill |

## Moved from the programme's documents

- *(the programme's docs/1.2 §3.2)* The next structural release takes the major slot: `1.0.0`.
