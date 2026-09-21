#!/usr/bin/env python3
"""check-api-errors.py — every error the API can return is documented in 4.3.

**An error is part of the interface** (#329). A caller writes code against
*"Current password is incorrect"* as surely as against the shape of the response
carrying it, and the web client already renders whatever string the server
sends — so the server's wording is on a player's screen, undeclared.

**A gate since 2026-09-21, and it was a check before that for a reason that has
expired.** Documenting an error is writing, and a build must not go red over
writing that has not happened yet — so while the debt was 44 it reported and a
person decided. The debt is now nil: all 70 messages the API can construct are
in 4.3, against the endpoints that return them. What is left to protect is that
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

Exit 1 on an undocumented message, per `docs/4.8`: 1 is fatal, and this is a
gate. `check-docs.sh` runs it, and CI runs `check-docs.sh` on every push, so the
message that reaches a player and the line describing it now ship together or
not at all.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "crates" / "server-game" / "src"
DOC = ROOT / "docs" / "4.3-api-schema.md"

# `ApiProblem::kind("literal"` — the first argument only, and only where it is a
# literal. A message built with `format!` carries a runtime value and cannot be
# matched against a document, so it is out of scope rather than silently missed.
# `Self::` as well as `ApiProblem::`, because `error.rs` builds problems from
# inside the impl — `from_sqlx` answers two messages of its own and neither was
# seen here, so the check said all messages were documented while two were not.
# Found 2026-09-17 while shipping #380.
CALL = re.compile(r'(?:ApiProblem|Self)::(\w+)\(\s*"([^"]+)"')

# Not an interface: `tests.rs` asserts against these strings, and counting a
# test's copy would let a message be "documented" by being tested.
SKIP = {"tests.rs"}


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


def literals() -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for f in sorted(SRC.rglob("*.rs")):
        if f.name in SKIP:
            continue
        for m in CALL.finditer(f.read_text()):
            found.setdefault(runtime_text(m.group(2)), set()).add(f"{f.relative_to(ROOT)}")
    return found


def main() -> int:
    if not DOC.exists():
        print(f"check-api-errors: {DOC} not found", file=sys.stderr)
        return 0
    doc = DOC.read_text()
    found = literals()
    missing = {msg: files for msg, files in found.items() if msg not in doc}

    print(f"==> API errors, against {DOC.relative_to(ROOT)}")
    if not missing:
        print(f"  all {len(found)} error messages the API can return are documented")
        return 0

    print(f"  documented: {len(found) - len(missing)}    undocumented: {len(missing)}")
    for msg in sorted(missing):
        where = ", ".join(sorted(f.split("/")[-1] for f in missing[msg]))
        print(f"    {msg[:72]:74} {where}")
    print()
    print("  An error is part of the interface. Each belongs against the endpoint")
    print("  that returns it, as part of what that call does — #329.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
