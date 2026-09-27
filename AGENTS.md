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
  it already lives ([`docs/1.6-document-map.md`](docs/1.6-document-map.md) lists
  every heading) and link to it rather than repeating it. Do not describe what
  the project does not do, or add justification the reader does not need.
- **A numbered document holds one kind of content**: 1.x and 2.x explain, 3.x
  say how to do a task, 4.x are reference. It states what is true now, with at
  most a line of reason; history, argument and quotations go in the commit
  message or the issue ([`docs/3.9`](docs/3.9-writing-documents.md)).
  `scripts/doc-signals.py --list` shows lines that look like history.
- **`docs/1.6-document-map.md` is generated**: run
  `scripts/document-map.py --write` after changing any heading; do not edit it.
- **Process documents change only on `main`**, never on a project branch:
  `CLAUDE.md` and those listed by `scripts/board/documents.py`.
- **Never touch production**, and never run `scripts/deploy.sh`.

## Checking your change

```bash
scripts/check-docs.sh                                  # documentation: lint, links, placement, the map
bats scripts/tests                                     # the shell tooling
python3 -m unittest discover -s scripts -t scripts     # the Python tooling
cargo test --workspace                                 # the application
```

## A review rather than a change

If you were asked to review, report findings in the pull request body or a
comment, each with the file and the rule it breaks from `CLAUDE.md`. The owner
and Claude decide what to apply.
