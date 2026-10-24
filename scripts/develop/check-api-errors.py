#!/usr/bin/env python3
"""check-api-errors.py — every error the API can return is documented in 4.4.3.

**An error is part of the interface** (#329). A caller writes code against
*"Current password is incorrect"* as surely as against the shape of the response
carrying it, and the web client already renders whatever string the server
sends — so the server's wording is on a player's screen, undeclared.

**A gate since 2026-09-21, and it was a check before that for a reason that has
expired.** Documenting an error is writing, and a build must not go red over
writing that has not happened yet — so while the debt was 44 it reported and a
person decided. The debt is now nil: all 70 messages the API can construct are
in 4.4.3, against the endpoints that return them. What is left to protect is that
staying true, and a new error added without a line in the document is not a debt
somebody is working through, it is a regression. #329's third acceptance
condition asks for it to be *caught*, which a report cannot do.

**Why a check and not a generator**, which is the design question #329 settled:
a generator can list which literals an endpoint constructs, but not *why* two
conditions share one message. `/auth/login` returns *"Incorrect User ID or
password"* for a wrong password **and** for an account that does not exist,
deliberately, so a caller cannot enumerate display names — and it verifies a
decoy password on the miss so both paths cost the same. That is the behaviour a
caller needs, and none of it is derivable from the source. So a person writes
the entry and this verifies nothing was missed.

**It reads three kinds of source and compares two things** (#529). The first
version matched only `ApiProblem::x("literal"`, so it missed a message built with
`format!`, a literal with a comment between the bracket and the string, and the
`Err(String)` values of `game_state.rs` that the handlers pass on through
`map_err(ApiProblem::bad_request)` — about 25 messages absent from 4.4.3 while
it reported all 72 documented (#528). And it compared only the words, so a
message could sit in the document under the wrong status. Each message is now
looked up with its status as well, and a mismatch fails like an absence. Where
the document's line states no status the words alone are checked, and
`--unstated` lists those.

Exit 1 on an undocumented message or a wrong status, per `programme/applications/tile-lite-elite/3.1.2-artefacts.md`: 1 is fatal, and this is a
gate. `check-docs.sh` runs it, and CI runs `check-docs.sh` on every push, so the
message that reaches a player and the line describing it now ship together or
not at all.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "crates" / "server-game" / "src"
DOC = ROOT / "docs" / "4.4.3-api-schema.md"

# What `ApiProblem::kind` answers. Every constructor that takes a message, so a
# new one that is missing here stops the check rather than passing unseen.
STATUS = {
    "bad_request": 400,
    "blocked_by_games": 400,
    "unauthorized": 401,
    "forbidden": 403,
    "not_found": 404,
    "too_many_requests": 429,
    "internal": 500,
    "unavailable": 503,
}

# Between a bracket and the string a comment may sit, `//` or `/* */`, and the
# first version did not look past it.
GAP = r"(?:\s|//[^\n]*\n|/\*.*?\*/)*"

# A Rust string literal, with its escapes: `\"` does not end it.
LIT = r'"((?:[^"\\]|\\.)*)"'

# `ApiProblem::kind("literal"` or `ApiProblem::kind(format!("literal {x}"` — the
# first argument only. A `format!` message carries a runtime value, so what is
# compared is its fixed text (see `wildcard`).
# `Self::` as well as `ApiProblem::`, because `error.rs` builds problems from
# inside the impl — `from_sqlx` answers two messages of its own and neither was
# seen here, so the check said all messages were documented while two were not.
# Found 2026-09-17 while shipping #380.
CALL = re.compile(rf"(?:ApiProblem|Self)::(\w+)\({GAP}(format!\({GAP})?{LIT}", re.S)

# The one constructor whose message is its second argument: a unique violation
# answers it as a 400.
DUPLICATE = re.compile(rf"from_sqlx_or_duplicate\([^,]+,{GAP}{LIT}", re.S)

# `game_state.rs` returns `Err(String)`, and the handlers pass each on through
# `map_err(ApiProblem::bad_request)` — 400 whatever it says, which is why the
# call sites are not read. Anything before `#[cfg(test)]` can reach a caller.
STATE = SRC / "game_state.rs"

# `board_from_dto` is the exception: it runs only when a persisted game is loaded,
# where the caller `expect`s it, so its errors panic and no client is told them.
STATE_UNREACHED = re.compile(r"pub fn board_from_dto.*?\n}\n", re.S)
STATE_ERR = re.compile(
    rf"(?:\bErr\({GAP}|ok_or_else\(\|\|\s*|map_err\(\|\w+\|\s*)(format!\({GAP})?{LIT}", re.S
)

# `format_move_error` words every refusal of the move rules, and `game_state.rs`
# passes its text on with `map_err(|error| format_move_error(&error))`: a 400
# from `actions` that no `ApiProblem::` or `Err(` names. Only its body is read,
# and only the text it returns — not the `"is"`/`"are"` that choose a verb.
FORMAT = ROOT / "crates" / "rules-shared" / "src" / "format.rs"
MOVE_ARM = re.compile(rf"=>\s*{LIT}", re.S)
MOVE_FORMAT = re.compile(rf"format!\({GAP}{LIT}", re.S)

# **Messages the source builds that no caller receives**, each with the reason.
# Named one by one: a rule such as *another status wins* would also hide a
# message that really is lost, and each of these was traced by hand.
UNREACHABLE = {
    ("Only seated players can chat in this game", 400):
        "`post_chat` answers 403 first, so the game's own guard never answers",
    ("That seat isn't claimed", 400):
        "`withdraw_from_seat` answers 401 for a caller who does not hold the seat first",
    ("Rack no longer matches move", 400):
        "`validate_rack_usage` refuses a tile outside the rack first, as `Incorrect tile placement.`",
    ("Expected {} board cells, got {}", 400):
        "`board_from_dto` runs only when a persisted game is loaded, and its caller `expect`s it",
    ("{error:?}", 400):
        "`apply_move_to_game` repeats checks `validate_game_move` has just passed",
}

# **A 500 whose body is another library's text.** `hash_password_bounded` passes
# Argon2's own error through `map_err(ApiProblem::internal)`, with no literal for
# the scan to see; 4.4.3 documents it by description. Named here so that
# removing the pass-through, or adding another like it, is a decision.
PASSED_ON = {
    ("the Argon2 library's own error text", 500): ("app/auth.rs", ".map_err(ApiProblem::internal)"),
}

# Not an interface: `tests.rs` asserts against these strings, and counting a
# test's copy would let a message be "documented" by being tested.
SKIP = {"tests.rs"}

# **A historical mention disarms this check for the string it mentions.** The
# match is against the whole document, so prose saying *it used to answer
# `Database error`* is indistinguishable from an entry documenting that it
# still does — and a reintroduction of the retired message then passes.
#
# Found on 2026-09-22, in a line this project had itself written a day earlier:
# reverting one of #399's two call sites left the gate reporting all 70
# documented. **So a retired message is described, never quoted**, and that is a
# rule about writing this document rather than something the code can enforce.
# Quoting it would need the match narrowed to the behaviour tables, which is a
# larger change than the problem has so far justified.


# A Rust string literal broken with a trailing `\` continues on the next line,
# and the compiler drops the backslash, the newline and the leading whitespace.
# So the *source* holds formatting the caller never sees. Comparing the raw
# capture against a document could therefore never match, and two long admin
# messages read as undocumented no matter what was written. Found 2026-09-11
# while documenting them.
CONT = re.compile(r"\\\s*\n\s*")


def runtime_text(raw: str) -> str:
    """The string a caller receives, from the literal as it appears in source."""
    return CONT.sub("", raw)


def unescape(raw: str) -> str:
    return re.sub(r"\\(.)", r"\1", runtime_text(raw))


def wildcard(text: str, formatted: bool) -> re.Pattern | None:
    """The pattern a documented message must match.

    **4.4.3 writes a variable part as a placeholder**: `<x>` or `<n>` for a
    value, a bare `N` or `M` for a count, `(x, y)` and `WxH` for coordinates and
    a board, `{error}` or `…` for the text of another error. So a `format!`
    message is matched on its fixed text, each `{…}` standing for one
    placeholder — any run that does not leave the code span or the line.
    """
    if not formatted:
        return re.compile(re.escape(text))
    parts = re.split(r"(?<!\{)\{[^{}]*\}(?!\})", text)
    parts = [p.replace("{{", "{").replace("}}", "}") for p in parts]
    if not "".join(parts).strip():
        # Nothing fixed to look for: a wildcard alone matches every line, so
        # this is never "documented" and can only be named in UNREACHABLE.
        return None
    return re.compile("[^`\n]+?".join(re.escape(p) for p in parts))


def messages() -> dict[tuple[str, int], tuple[re.Pattern | None, set[str]]]:
    """(message as written in source, status) -> (its pattern, the files)."""
    found: dict[tuple[str, int], tuple[re.Pattern | None, set[str]]] = {}

    def note(f: Path, raw: str, formatted: bool, status: int) -> None:
        text = unescape(raw)
        pattern, files = found.setdefault((text, status), (wildcard(text, formatted), set()))
        files.add(f"{f.relative_to(ROOT)}")

    for f in sorted(SRC.rglob("*.rs")):
        if f.name in SKIP:
            continue
        source = f.read_text()
        for m in CALL.finditer(source):
            if m.group(1) in STATUS:
                note(f, m.group(3), bool(m.group(2)), STATUS[m.group(1)])
            elif m.group(1) not in ("from_sqlx", "from_sqlx_or_duplicate"):
                sys.exit(f"check-api-errors: ApiProblem::{m.group(1)} has no status in STATUS")
        for m in DUPLICATE.finditer(source):
            note(f, m.group(1), False, 400)
        if f == STATE:
            for m in STATE_ERR.finditer(source.split("#[cfg(test)]")[0]):
                note(f, m.group(2), bool(m.group(1)), 400)
    if FORMAT.exists():
        body = FORMAT.read_text().split("pub fn format_move_error", 1)[1].split("\n}\n", 1)[0]
        for m in MOVE_ARM.finditer(body):
            note(FORMAT, m.group(1), False, 400)
        for m in MOVE_FORMAT.finditer(body):
            note(FORMAT, m.group(1), True, 400)
    for (text, status), (file, needle) in PASSED_ON.items():
        if needle in (SRC / file).read_text():
            found[(text, status)] = (re.compile(re.escape(text)), {f"{(SRC / file).relative_to(ROOT)}"})
    for key in UNREACHABLE:
        found.pop(key, None)
    return found


def statuses(doc: str, pattern: re.Pattern) -> set[int] | None:
    """The statuses 4.4.3 gives a message, or None when it does not mention it.

    Read from the line the message is on: a table row carries its status in bold
    (`**404**`), and prose names it in passing. A message that appears on several
    lines, as `Game not found` does, has the union. **A line with no status gives
    the empty set, and is not a mismatch**: most rows state a status only where it
    is not the section's usual one, so silence is how the document writes the
    common case, and the check cannot tell it from an omission.
    """
    found: set[int] | None = None
    for m in pattern.finditer(doc):
        line = doc[doc.rfind("\n", 0, m.start()) + 1 : doc.find("\n", m.end())]
        codes = re.findall(r"\*\*([45]\d\d)\*\*", line) or re.findall(r"\b([45]\d\d)\b", line)
        found = (found or set()) | {int(c) for c in codes}
    return found


def main() -> int:
    if not DOC.exists():
        print(f"check-api-errors: {DOC} not found", file=sys.stderr)
        return 0
    doc = DOC.read_text()
    found = messages()
    missing, wrong, unstated = {}, {}, {}
    for (msg, status), (pattern, files) in found.items():
        documented = statuses(doc, pattern) if pattern else None
        if documented is None:
            missing[(msg, status)] = files
        elif not documented:
            unstated[(msg, status)] = files
        elif status not in documented:
            wrong[(msg, status)] = (documented, files)

    print(f"==> API errors, against {DOC.relative_to(ROOT)}")
    if unstated:
        print(f"  {len(unstated)} are documented on a line that gives no status, so only their wording was checked")
        if "--unstated" in sys.argv:
            for msg, status in sorted(unstated):
                print(f"    {status} {msg[:70]}")
    if not missing and not wrong:
        print(f"  all {len(found)} error messages the API can return are documented, none with a wrong status")
        return 0

    print(f"  checked: {len(found)}    undocumented: {len(missing)}    wrong status: {len(wrong)}")
    for msg, status in sorted(missing):
        where = ", ".join(sorted(f.split("/")[-1] for f in missing[(msg, status)]))
        print(f"    {status} {msg[:70]:72} {where}")
    for msg, status in sorted(wrong):
        documented, files = wrong[(msg, status)]
        where = ", ".join(sorted(f.split("/")[-1] for f in files))
        said = "/".join(map(str, sorted(documented)))
        print(f"    {status} {msg[:70]:72} {where}  (4.4.3 says {said})")
    print()
    print("  An error is part of the interface. Each belongs against the endpoint")
    print("  that returns it, with the status it answers, as part of what that")
    print("  call does — #329.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
