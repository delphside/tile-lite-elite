# Agents working in this repository

For any coding agent that is not Claude Code: GitHub Copilot, Codex and others
that read this file. The rules themselves are in [`CLAUDE.md`](CLAUDE.md), which
owns them; read it before changing anything. This file says only what an agent
must know to avoid breaking something on its first change.

## Before you change anything

- **Commit subjects start with the version stamp**, `app X.Y.Z api M.N:` and a
  space, with the versions from `Cargo.toml` and `crates/api/src/lib.rs`. CI
  refuses a commit without it.
- **Name the issue a commit serves** with a `Refs #N` trailer. Branches are
  named `N-short-name` for their issue.
- **Documentation has one home for each fact.** Before adding text, find where
  it already lives ([`docs/4.1.6-document-map.md`](docs/4.1.6-document-map.md) lists
  every heading) and link to it rather than repeating it. Do not describe what
  the project does not do, or add justification the reader does not need.
- **Each numbered group covers one scope.** This application's documents are
  4.1 to 4.4 in `docs/` (overview, design, development and operation,
  reference); the programme's are 1.x and 2.x in `delphside/programme`, and this
  application's records there are 3.1.x. A document states what is true now,
  with at most a line of reason; history, argument and quotations go in the commit
  message or the issue ([`docs/1.5`](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md)).
  `scripts/programme/docs/doc-signals.py --list` shows lines that look like
  history.
- **`docs/4.1.6-document-map.md` is generated**: run
  `scripts/programme/docs/document-map.py --write` after changing any heading;
  do not edit it.
- **Programme documents change only on `main`**, never on a project branch:
  those `scripts/programme/board/documents.py` classes as the programme's,
  including `CLAUDE.md`, this file and every change note.
- **Never touch production**, and never run `scripts/deploy.sh`.

## Checking your change

```bash
scripts/programme/docs/check-docs.sh                  # documentation: lint, links, placement, the map
bats scripts/tests                                    # the shell tooling
python3 -m unittest discover -s scripts -t scripts    # the Python tooling's checks
python3 -m unittest discover -s scripts/programme -t scripts/programme  # the board model's
cargo test --workspace                                # the application
```

## A review rather than a change

If you were asked to review, look first for a review brief in the issue's
folder under `applications/tile-lite-elite/3.1.7-changes/` in the programme's
live checkout (`delphside/programme`, beside this repository or `PROGRAMME_DIR`;
`<issue>-review-brief.md`). It says what to review, and you write your findings
into it, in a pull request to `delphside/programme` that changes that file and
no other. Never change the `programme/` submodule here: it is a pinned, read-only
copy. Without a brief, report findings in the conversation,
each with the file and the rule it breaks from `CLAUDE.md`. Either way, change
nothing else: the owner and Claude decide what to apply.
