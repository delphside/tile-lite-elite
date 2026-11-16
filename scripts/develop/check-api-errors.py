#!/usr/bin/env python3
"""check-api-errors.py — every error the API can return, and every reason, is in 4.4.3.

**An error is part of the interface** (#329). A caller writes code against
*"Current password is incorrect"* as surely as against the shape of the response
carrying it, and the web client renders whatever string the server sends — so
the server's wording is on a player's screen, undeclared. Since #606 a caller
also writes code against the `reason` that classifies it, and the admin CLI
exits by it.

**It compares three things, and refuses on any difference** (#606):

  1. **The `Reason` enum in `crates/api` and the *Reasons* table in 4.4.3**, both
     ways and row by row: a reason without a row, a row without a reason, and a
     row whose status, type or blip differs from the enum's `class` match. A row
     with no status is a failure, not a note.
  2. **Every message the server can construct, with its reason**: each is looked
     up on a line of 4.4.3 that names the reason as `` `SIGN_IN_REQUIRED` `` and
     states the status the enum gives that reason, in bold (`**401**`). A message
     under the wrong reason or no status fails like an absence.
  3. **The status table's *Type* column**, against the type the enum gives every
     reason that answers that status.

**It is a gate, silent when the code and the document agree** (exit 0, no
output), and prints what differs and exits 1 otherwise, per
`programme/applications/tile-lite-elite/3.1.2-artefacts.md`: 1 is fatal, and this
is a gate. `check-docs.sh` runs it, and CI runs `check-docs.sh` on every push, so
the message that reaches a player and the line describing it ship together or not
at all.

**Why a check and not a generator**, which is the design question #329 settled:
a generator can list which literals an endpoint constructs, but not *why* two
conditions share one message. `/auth/login` answers *"Incorrect User ID or
password"* for a wrong password **and** for an account that does not exist,
deliberately, so a caller cannot enumerate display names. A person writes the
entry and this verifies nothing was missed.

**What it reads.** `ApiProblem::new(Reason::X, "literal")`, `Refusal::new` and
`refusal!` (the `game_state.rs` refusals the handlers pass on), the sign-in
helpers `require_session` and `no_session` (reason `SignInRequired`), a message
held in a constant such as `INTERNAL_MESSAGE`, `from_sqlx_or_duplicate`, and the
move-rule text `format_move_error` returns (reason `MoveRefused`). Anything
before an inline `#[cfg(test)] mod` is read, since that is what can reach a
caller; a file named `tests*.rs` is not, because a test's copy of a message
would let one be "documented" by being tested.

**A historical mention disarms this check for the string it mentions.** The match
is against the whole document, so prose saying *it used to answer `Database
error`* is indistinguishable from an entry documenting that it still does. So a
retired message is described, never quoted (found 2026-09-22, #380).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "crates" / "server-game" / "src"
API = ROOT / "crates" / "api" / "src" / "lib.rs"
DOC = ROOT / "docs" / "4.4.3-api-schema.md"

# Between a bracket and the string a comment may sit, `//` or `/* */`.
GAP = r"(?:\s|//[^\n]*\n|/\*.*?\*/)*"

# A Rust string literal, with its escapes: `\"` does not end it.
LIT = r'"((?:[^"\\]|\\.)*)"'

# The constructors that take a reason and a message. A message is a literal, a
# `format!` of one, or the name of a constant; `refusal!` always formats.
CALL = re.compile(
    rf"(ApiProblem::new|Self::new|Refusal::new|refusal!)\({GAP}Reason::(\w+),{GAP}"
    rf"(?:(format!\({GAP})?{LIT}|([A-Z][A-Z_]*)\b)",
    re.S,
)

# `from_sqlx_or_duplicate(error, Reason::X, "literal")`: a unique violation
# answers it.
DUPLICATE = re.compile(rf"from_sqlx_or_duplicate\([^,]+,{GAP}Reason::(\w+),{GAP}{LIT}", re.S)

# The sign-in helpers answer `SignInRequired` with the verb's sentence, and
# `SessionExpired` with a sentence of their own, which is read as a literal.
SIGN_IN = re.compile(
    rf"\b(?:require_session\([^,()]+,\s*[^,()]+|no_session\([^,()]+),{GAP}{LIT}", re.S
)

# `const NAME: &str = "literal";`, for the messages a constant holds.
CONST = re.compile(rf"const ([A-Z][A-Z_]*): &str\s*=\s*{LIT};")

# `format_move_error` words every refusal of the move rules; `game_state.rs`
# passes its text on as a `MoveRefused`. Only its body is read, and only the text
# it returns — not the `"is"`/`"are"` that choose a verb.
FORMAT = ROOT / "crates" / "rules-shared" / "src" / "format.rs"
MOVE_ARM = re.compile(rf"=>\s*{LIT}", re.S)
MOVE_FORMAT = re.compile(rf"format!\({GAP}{LIT}", re.S)

# Every `ApiProblem::` constructor a call may name. A new one is not read, so it
# stops the check rather than passing unseen: the per-status constructors went at
# #606 so that a refusal names its reason.
KNOWN = {"new", "from", "from_sqlx", "from_sqlx_or_duplicate", "internal"}

# **Messages the source builds that no caller receives**, each with the reason.
# Named one by one: a rule such as *another status wins* would also hide a message
# that really is lost, and each of these was traced by hand. Keyed by the file
# too, so the same words reachable from another file are still held to the
# document. **A key the scan does not find fails the check**: the message was
# reworded, moved or removed, and an exclusion left behind would quietly hide
# whatever next takes those words.
UNREACHABLE = {
    ("game_state.rs", "That seat isn't claimed", "SeatNotClaimed"):
        "`withdraw_from_seat` answers `NotYourSeat` for a caller who does not hold the seat first",
    ("game_state.rs", "Rack no longer matches move", "MoveRefused"):
        "`validate_rack_usage` refuses a tile outside the rack first, as `Incorrect tile placement.`",
    ("game_state.rs", "Expected {} board cells, got {}", "MoveRefused"):
        "`board_from_dto` runs only when a persisted game is loaded, and its caller `expect`s it",
    ("game_state.rs", "{error:?}", "MoveRefused"):
        "`apply_move_to_game` repeats checks `validate_game_move` has just passed",
}

# A Rust string literal broken with a trailing `\` continues on the next line,
# and the compiler drops the backslash, the newline and the leading whitespace.
# So the *source* holds formatting the caller never sees.
CONT = re.compile(r"\\\s*\n\s*")

INLINE_TESTS = re.compile(r"#\[cfg\(test\)\]\s*mod \w+ \{")


def runtime_text(raw: str) -> str:
    """The string a caller receives, from the literal as it appears in source."""
    return CONT.sub("", raw)


def unescape(raw: str) -> str:
    return re.sub(r"\\(.)", r"\1", runtime_text(raw))


def code_of(name: str) -> str:
    """`SignInRequired` as it is serialised: `SIGN_IN_REQUIRED`."""
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).upper()


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


def classes(api_source: str) -> tuple[dict[str, tuple[int, str, bool]], list[str]]:
    """{variant: (status, type, blip)} from `Reason::class`, and what is wrong with it."""
    problems = []
    body = api_source.split("pub enum Reason {", 1)[1].split("\n}\n", 1)[0]
    variants = re.findall(r"^\s{4}([A-Z]\w*),\s*$", body, re.M)
    arms = {
        m.group(1): (int(m.group(2)), m.group(3).lower(), m.group(4) == "true")
        for m in re.finditer(
            r"Self::(\w+)\s*=>\s*\((\d+),\s*ErrorType::(\w+),\s*(true|false)\)", api_source
        )
    }
    for variant in variants:
        if variant not in arms:
            problems.append(f"Reason::{variant} has no arm in Reason::class")
    for variant in arms:
        if variant not in variants:
            problems.append(f"Reason::class has an arm for {variant}, which is not a variant")
    return {v: arms[v] for v in variants if v in arms}, problems


def table_rows(doc: str, heading: str) -> list[list[str]]:
    """The rows of the first table after `heading`, as lists of trimmed cells."""
    at = doc.find(heading)
    if at < 0:
        return []
    rows, started = [], False
    for line in doc[at + len(heading):].split("\n"):
        if line.startswith("|"):
            started = True
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if set("".join(cells)) <= set("-: "):
                continue
            rows.append(cells)
        elif started:
            break
    return rows[1:]  # without the header


def compare_reasons(doc: str, reasons: dict[str, tuple[int, str, bool]]) -> list[str]:
    """The *Reasons* table against the enum, both ways, row by row."""
    problems = []
    rows = table_rows(doc, "\n### Reasons\n")
    if not rows:
        return ["4.4.3 has no `### Reasons` table"]
    by_code = {}
    for cells in rows:
        match = re.fullmatch(r"`([A-Z][A-Z_]*)`", cells[0]) if cells else None
        if not match or len(cells) < 6:
            problems.append(f"a row of the Reasons table is not `REASON` | status | type | blip | …: {cells[:1]}")
            continue
        by_code[match.group(1)] = cells
    expected = {code_of(v): (v, c) for v, c in reasons.items()}
    for code, (variant, (status, kind, blip)) in expected.items():
        cells = by_code.get(code)
        if cells is None:
            problems.append(f"Reason::{variant} ({code}) has no row in the Reasons table")
            continue
        said_status = re.fullmatch(r"\*{0,2}(\d{3})\*{0,2}", cells[1])
        if not said_status:
            problems.append(f"{code}: the Reasons table states no status (the enum says {status})")
        elif int(said_status.group(1)) != status:
            problems.append(f"{code}: the Reasons table says status {said_status.group(1)}, the enum says {status}")
        if cells[2].lower() != kind:
            problems.append(f"{code}: the Reasons table says type {cells[2]!r}, the enum says {kind!r}")
        if cells[3].lower() != ("yes" if blip else "no"):
            problems.append(f"{code}: the Reasons table says blip {cells[3]!r}, the enum says {'yes' if blip else 'no'!r}")
    for code in by_code:
        if code not in expected:
            problems.append(f"the Reasons table has a row for {code}, which is not a Reason")
    return problems


def compare_status_types(doc: str, reasons: dict[str, tuple[int, str, bool]]) -> list[str]:
    """The status table's *Type* column against the type the enum gives that status."""
    problems = []
    rows = table_rows(doc, "\n### Status codes")
    if not rows:
        return ["4.4.3 has no status table under `### Status codes`"]
    said = {}
    for cells in rows:
        code = re.sub(r"[`*]", "", cells[0])
        if code.isdigit() and len(cells) >= 3:
            said[int(code)] = cells[2].lower()
    for variant, (status, kind, _blip) in reasons.items():
        if status not in said:
            problems.append(f"{code_of(variant)} answers {status}, which has no row in the status table")
        elif not said[status].startswith(kind):
            problems.append(
                f"the status table gives {status} the type {said[status]!r}; {code_of(variant)} is {kind!r}"
            )
    return problems


def messages():
    """The messages, and what is wrong with the exclusions themselves.

    Returns ({(message as written in source, reason): (its pattern, the files)},
    [what is stale or unnamed]).
    """
    found: dict[tuple[str, str], tuple[re.Pattern | None, set[str]]] = {}
    where: set[tuple[str, str, str]] = set()
    stale: list[str] = []

    def note(f: Path, raw: str, formatted: bool, reason: str) -> None:
        text = unescape(raw)
        found.setdefault((text, reason), (wildcard(text, formatted), set()))[1].add(f"{f.relative_to(ROOT)}")
        where.add((f"{f.relative_to(SRC) if f.is_relative_to(SRC) else f.name}", text, reason))

    sources = {}
    for f in sorted(SRC.rglob("*.rs")):
        if f.name.startswith("tests"):
            continue
        source = f.read_text()
        sources[f] = INLINE_TESTS.split(source)[0]
    constants = {m.group(1): m.group(2) for source in sources.values() for m in CONST.finditer(source)}
    for f, source in sources.items():
        for m in CALL.finditer(source):
            kind, reason, formatted, literal, name = m.groups()
            if literal is not None:
                note(f, literal, bool(formatted) or kind == "refusal!", reason)
            elif name in constants:
                note(f, constants[name], False, reason)
        for m in DUPLICATE.finditer(source):
            note(f, m.group(2), False, m.group(1))
        for m in SIGN_IN.finditer(source):
            note(f, m.group(1), False, "SignInRequired")
        for m in re.finditer(r"ApiProblem::(\w+)\(", source):
            if m.group(1) not in KNOWN:
                stale.append(
                    f"{f.relative_to(SRC)}: ApiProblem::{m.group(1)} is not a constructor this check reads; "
                    "a refusal is ApiProblem::new(Reason::X, message)"
                )
    if FORMAT.exists():
        body = FORMAT.read_text().split("pub fn format_move_error", 1)[1].split("\n}\n", 1)[0]
        for m in MOVE_ARM.finditer(body):
            note(FORMAT, m.group(1), False, "MoveRefused")
        for m in MOVE_FORMAT.finditer(body):
            note(FORMAT, m.group(1), True, "MoveRefused")
    else:
        stale.append(f"{FORMAT.relative_to(ROOT)} not found: the move-rule messages cannot be read")
    for (file, text, reason) in UNREACHABLE:
        if (file, text, reason) not in where:
            stale.append(f"UNREACHABLE names {text!r} ({reason}) in {file}, which the scan does not find")
            continue
        entry = found[(text, reason)]
        entry[1].discard(f"{SRC.relative_to(ROOT)}/{file}")
        if not entry[1]:
            del found[(text, reason)]
    return found, stale


def check_message(doc: str, pattern: re.Pattern, reason: str, status: int) -> str | None:
    """Why no line of 4.4.3 documents the message under its reason, or None.

    A message that appears on several lines, as `Game not found` does, needs one
    line that names the reason and states the status in bold.
    """
    code, bold = f"`{code_of(reason)}`", f"**{status}**"
    lines = []
    for m in pattern.finditer(doc):
        lines.append(doc[doc.rfind("\n", 0, m.start()) + 1 : doc.find("\n", m.end())])
    if not lines:
        return "not in 4.4.3"
    if any(code in line and bold in line for line in lines):
        return None
    if not any(code in line for line in lines):
        named = sorted({c for line in lines for c in re.findall(r"`([A-Z][A-Z_]+)`", line)})
        return f"its line names no {code_of(reason)}" + (f" (it names {', '.join(named)})" if named else "")
    return f"its line states no {bold}, which is {code_of(reason)}'s status"


def main() -> int:
    if not DOC.exists():
        print(f"check-api-errors: {DOC} not found", file=sys.stderr)
        return 0
    doc = DOC.read_text()
    reasons, problems = classes(API.read_text())
    problems += compare_reasons(doc, reasons)
    problems += compare_status_types(doc, reasons)
    found, stale = messages()
    problems += [f"STALE  {s}" for s in stale]
    refused = []
    for (msg, reason), (pattern, files) in sorted(found.items()):
        if reason not in reasons:
            problems.append(f"{msg[:60]!r} names Reason::{reason}, which is not in the enum")
            continue
        why = check_message(doc, pattern, reason, reasons[reason][0]) if pattern else "not in 4.4.3"
        if why:
            where = ", ".join(sorted(f.split("/")[-1] for f in files))
            refused.append(f"{reasons[reason][0]} {code_of(reason):26} {msg[:60]!r}: {why}  [{where}]")
    if not problems and not refused:
        return 0

    print(f"==> API errors, against {DOC.relative_to(ROOT)}")
    for problem in problems:
        print(f"  {problem}")
    for line in refused:
        print(f"  {line}")
    print()
    print("  An error is part of the interface. Each reason has a row in the Reasons")
    print("  table, and each message a line that names its reason and states its")
    print("  status, against the endpoint that returns it — #329, #606.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
