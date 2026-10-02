#!/usr/bin/env bash
# comment-check.sh — before Claude comments on an issue, say what the owner has
# said there that nobody has answered (#454 R5).
#
# Runs on PreToolUse for Bash. It only reads the command: a `gh issue comment N`,
# a `gh issue close N --comment`, or a `gh api` call to `issues/N/comments`. For
# any other command it says nothing. The to-do list at session start is a
# snapshot; this is the same rule, read for one issue at the moment of writing,
# so the comment can answer what is open rather than leave it for the list.
#
# **A check, not a gate.** It reports and Claude decides: the comment may be
# the answer. It never blocks, and never fails: every path exits 0.
#
# `COMMENT_CHECK_INBOX` replaces the command that reads the issue, so the
# matching can be tested without GitHub.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 0
INBOX="${COMMENT_CHECK_INBOX:-./scripts/programme/board/board-inbox.py}"

CMD="$(timeout 2 cat 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))
except Exception:
    pass
' 2>/dev/null)"
[[ -n "$CMD" ]] || exit 0

N="$(printf '%s' "$CMD" | sed -nE 's/.*gh issue (comment|close) +#?([0-9]+).*/\1 \2/p; s/.*gh api [^ ]*issues\/([0-9]+)\/comments.*/api \1/p' | head -1)"
KIND="${N%% *}"; N="${N##* }"
[[ "$N" =~ ^[0-9]+$ ]] || exit 0
# `gh issue close` is a comment only with --comment or -c.
[[ "$KIND" == "close" && ! "$CMD" =~ (--comment|\ -c\ ) ]] && exit 0

OPEN="$(timeout 20 "$INBOX" --open --issue "$N" --no-colour 2>/dev/null | grep -E '^  > ')" || exit 0
[[ -n "$OPEN" ]] || exit 0

python3 -c '
import sys, json
n, text = sys.argv[1], sys.argv[2]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": f"#{n} has comments from Steve that no comment of yours has answered. Make sure this one answers them, or say why not:\n{text}",
}}))
' "$N" "$OPEN" 2>/dev/null
exit 0
