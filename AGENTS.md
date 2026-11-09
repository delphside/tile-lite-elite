# Agents working in this repository

For any coding agent that is not Claude Code: GitHub Copilot, Codex and others
that read this file. The rules themselves are in [`CLAUDE.md`](CLAUDE.md), which
owns them; read it before changing anything. This file says only what an agent
must know to avoid breaking something on its first change.

## Before you change anything

- **Commit subjects start with the version stamp**, `app X.Y.Z api M.N:` and a
  space: `X.Y.Z` is the application version in `Cargo.toml`, `M.N` the API
  version in `crates/api/src/lib.rs`. CI refuses a commit without it
  ([4.3.3](docs/4.3.3-testing-ci-and-release.md#241-check-the-commit-subject-carries-both-versions)).
- **Name the issue a commit serves** with a `Refs #N` trailer, or
  `Activity: <id>` for an activity; never `Closes #N`, because no merge closes
  an issue. Name a branch `N-short-name` for the project or work package it
  delivers.
- **Documentation has one home for each fact.** Before adding text, find where
  it already lives ([`docs/4.1.6-document-map.md`](docs/4.1.6-document-map.md)
  lists every heading) and link to it. Write only what the reader needs.
- **Each numbered range covers one scope.** This application's documents are
  4.1 to 4.4 in `docs/`; the programme's are 1.x and 2.x in
  `delphside/programme`, and this application's records there are 3.1.x
  ([`docs/1.5`](https://github.com/delphside/programme/blob/main/docs/1.5-writing-documents.md#each-range-covers-one-scope)).
- **A document states what is true now**, with at most a line of reason;
  history, argument and quotations go in the commit message or the issue.
  `programme/scripts/docs/doc-signals.py --list` shows lines that look like
  history.
- **`docs/4.1.6-document-map.md` is generated, so do not edit it by hand**:
  run `programme/scripts/docs/document-map.py --write` after changing any
  heading.
- **Programme documents change only on `main`**, never on a project branch.
  `programme/scripts/board/documents.py` classes these, among others, as
  programme documents:
  - `CLAUDE.md`, this file and `docs/README.md`
  - the roadmap, `docs/4.1.4-roadmap.md`
- **Never touch production**, and never run `scripts/deliver/deploy.sh`.

## Checking your change

These are the commands in
[4.3.3](docs/4.3.3-testing-ci-and-release.md#22-running-tests):

```bash
programme/scripts/docs/check-docs.sh                  # documentation: lint, links, placement, the map
bats scripts/tests                                    # the shell tooling
python3 -m unittest discover -s scripts -t scripts    # the Python tooling's checks
cargo test --workspace                                # the application
```

## A review rather than a change

- **With a review brief:** the brief names what to review and holds the
  findings. It is `<issue>-review-brief.md`, where `<issue>` is the issue
  number of the project (of its parent, for a work package), in that project's
  change folder, `<issue>-<name>/`, under
  `applications/tile-lite-elite/3.1.7-changes/workstreams/<workstream>/`,
  in the programme's live checkout (`delphside/programme`, beside this
  repository or `PROGRAMME_DIR`). Write the findings into it, in a pull request
  to `delphside/programme` that changes that file and no other.
- **Without a brief:** report the findings in the conversation, each with the
  file and the rule it breaks from `CLAUDE.md`.

Change nothing else: the owner and Claude decide what to apply. The
`programme/` submodule here is a pinned, read-only copy.
