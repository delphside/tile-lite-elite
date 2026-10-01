#!/usr/bin/env bash
# issue-mentions.sh — how many commits reachable from a ref mention an issue.
#
# Sourced by `deploy.sh` (the milestone gate) and `verify.sh` (the milestone
# check). One function in one file because the alternative was two copies, and
# two copies is how the same defect came to exist in two places: #194 found it
# in `deploy.sh`, and `verify.sh` carried the identical line untouched.
#
# The defect, for anyone tempted to write the obvious thing again:
#
#     git log --oneline "$ref" --grep="#${num}\b" | grep -q .
#
# `grep -q` exits on its first match, `git log` keeps writing, takes SIGPIPE and
# dies with 141. Under `set -o pipefail` the *pipeline* is 141, so the `if`
# takes the else branch — reporting "no commit mentions this" precisely because
# it found one. Measured on #174 from d2adc63, 50 matching commits: 10 runs out
# of 10 report failure.
#
# `git rev-list --count` has no pipe, so there is no race to lose, and it
# answers with a number rather than a boolean — which is more use in the message
# the caller prints.

# commits_mentioning <ref> <issue-number> -> prints a count, always 0 or more.
#
# **The trailer, not any mention.** D40 (#320). `CLAUDE.md`: *"Commits say
# `Refs #N`, or `Closes #N` only when the change never leaves the repository."*
# So the trailer is what claims a commit *belongs* to an issue, and a bare `#N`
# anywhere in the message is a citation.
#
# The owner, 2026-09-05: *"I thought that was already the convention, Closes #N
# triggers a close. We need to be able to mention issues without automatically
# updating them."* The convention was GitHub's before it was ours — `Closes #N`
# closes an issue when the commit reaches the default branch, which is the whole
# reason this project reserves `Closes` and uses `Refs` otherwise.
#
# Matching any `#N` refused the 0.7.2 release: `b231721` changed one
# documentation file, carried `Refs #299`, and named #224 and #241 in its prose
# as examples of projects sitting in `no-release`. The milestone gate read that
# as both of them shipping, and its advice — move them into the release
# milestone — would have closed two projects that had shipped nothing.
#
# Measured at 9293893: this drops exactly the prose mentions and keeps every
# real one. #103 4 -> 3, #224 and #241 1 -> 0, #299 unchanged at 64.
#
# Case-sensitive deliberately: all 387 `Refs` and 3 `Closes` trailers in the
# history are capitalised, so this enforces the convention rather than
# tolerating drift away from it.
#
# `|| echo 0` because an unknown ref must not abort a deploy that has already
# passed every other gate: not knowing is reported as "nothing mentions it",
# which is the safe direction — it warns rather than closing an issue silently.
#
# **The rule is the model's** (`scripts/programme/board/refs.py`, #421): this asks it
# through `board-refs.py` rather than keeping its own pattern.
commits_mentioning() {
  local ref="$1" num="$2"
  python3 "$(dirname "${BASH_SOURCE[0]}")/../../programme/board/board-refs.py" -C "${REPO_DIR:-.}" count "$ref" "$num" \
    </dev/null 2>/dev/null || echo 0
}
