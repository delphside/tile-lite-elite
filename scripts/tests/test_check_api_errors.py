"""check-api-errors.py: the reasons it compares and the messages it finds, #529, #606.

The check once said all 72 messages were documented while about 25 were not,
because it matched only `ApiProblem::x("literal"`. Since #606 it also holds the
`Reason` enum to 4.4.3's *Reasons* table, and each message to a line that names
its reason and states its status. Each case here is built into a small source
tree and a small document so that the answer is known before the check is run.
"""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

from board.tests.cases import Cases

SCRIPT = Path(__file__).resolve().parents[1] / "develop" / "check-api-errors.py"

API = '''
pub enum Reason {
    SignInRequired,
    GameNotFound,
    NotYourSeat,
    GameNotWaiting,
    UnknownSeat,
    NotYourTurn,
    MoveRefused,
    Internal,
}

impl Reason {
    pub const fn class(self) -> (u16, ErrorType, bool) {
        match self {
            Self::SignInRequired => (401, ErrorType::Technical, false),
            Self::GameNotFound => (404, ErrorType::Business, false),
            Self::NotYourSeat => (403, ErrorType::Business, false),
            Self::GameNotWaiting => (400, ErrorType::Business, false),
            Self::UnknownSeat => (400, ErrorType::Business, false),
            Self::NotYourTurn => (400, ErrorType::Business, false),
            Self::MoveRefused => (400, ErrorType::Business, false),
            Self::Internal => (500, ErrorType::Unexpected, false),
        }
    }
}
'''

HANDLER = '''
fn handler() -> Result<(), ApiProblem> {
    let me = require_session(&state, &headers, "Sign in to start a game").await?;
    Err(ApiProblem::new(Reason::GameNotFound, format!("No player named '{name}'")))?;
    Err(ApiProblem::new(
        Reason::NotYourSeat,
        // the guard, not the game
        "This seat belongs to a different player",
    ))?;
    Err(ApiProblem::new(Reason::Internal, INTERNAL_MESSAGE))?;
    game.start().map_err(ApiProblem::from)?;
    Ok(())
}
'''

ERROR = '''
pub(crate) const INTERNAL_MESSAGE: &str = "Something went wrong on the server.";
'''

STATE = '''
fn start(&mut self) -> Result<(), Refusal> {
    if self.started {
        return Err(Refusal::new(Reason::GameNotWaiting, "The game has already started"));
    }
    let seat = self.seat(n).ok_or_else(|| refusal!(Reason::UnknownSeat, "Unknown seat {n}"))?;
    Err(refusal!(Reason::NotYourTurn, "It is not seat {seat_number}'s turn", seat_number))
}

#[cfg(test)]
mod tests {
    fn t() { Err(Refusal::new(Reason::MoveRefused, "A message only a test asserts")) }
}
'''

FORMAT = '''
pub fn format_move_error(error: &MoveError) -> String {
    match error {
        MoveError::InvalidWord(words) => {
            let verb = if words.len() == 1 { "is" } else { "are" };
            format!("{} {verb} not in the dictionary.", list(words))
        }
        MoveError::TilesDoNotFit => "Incorrect tile placement.".to_string(),
    }
}
'''

# Guards the check names as unreachable, and a message made only of placeholders.
GUARDS = '''
fn guards() -> Result<(), Refusal> {
    return Err(Refusal::new(Reason::MoveRefused, "Rack no longer matches move"));
    return Err(refusal!(Reason::MoveRefused, "Expected {} board cells, got {}", a, b));
    x.map_err(|error| refusal!(Reason::MoveRefused, "{error:?}"))?;
}
'''

# How 4.4.3 writes them: a variable part as `<x>`, `N`, `{error}`; the reason and
# the status in bold on the same line.
DOC = """
### Status codes: what each one means

| Code | HTTP text | Type | Meaning | What the caller does |
| --- | --- | --- | --- | --- |
| `400` | Bad Request | business | Broke a rule | Fix it |
| `401` | Unauthorized | technical, fundamental | Not signed in | Sign in |
| `403` | Forbidden | business | Not allowed | Nothing |
| `404` | Not Found | business | No such thing | Nothing |
| `500` | Internal Server Error | unexpected | It failed | Report it |

### Reasons

| Reason | Status | Type | Blip | What the caller does | What is logged |
| --- | --- | --- | --- | --- | --- |
| `SIGN_IN_REQUIRED` | **401** | technical | no | Sign in | a line |
| `GAME_NOT_FOUND` | **404** | business | no | Nothing | a line |
| `NOT_YOUR_SEAT` | **403** | business | no | Nothing | a line |
| `GAME_NOT_WAITING` | **400** | business | no | Fix it | a line |
| `UNKNOWN_SEAT` | **400** | business | no | Fix it | a line |
| `NOT_YOUR_TURN` | **400** | business | no | Fix it | a line |
| `MOVE_REFUSED` | **400** | business | no | Fix it | a line |
| `INTERNAL` | **500** | unexpected | no | Report it | a line |

| | |
| --- | --- |
| `Sign in to start a game` | `SIGN_IN_REQUIRED` **401**. No bearer token |
| `No player named '<x>'` | `GAME_NOT_FOUND` **404**. A `named` claim whose player does not exist |
| `This seat belongs to a different player` | `NOT_YOUR_SEAT` **403** |
| `Something went wrong on the server.` | `INTERNAL` **500** |
| `The game has already started` | `GAME_NOT_WAITING` **400** |
| `Unknown seat <n>` | `UNKNOWN_SEAT` **400** |
| `It is not seat N's turn` | `NOT_YOUR_TURN` **400** |
| `<words> is/are not in the dictionary.` · `Incorrect tile placement.` | `MOVE_REFUSED` **400** |
"""

NAMED = {
    ("game_state.rs", text, "MoveRefused"): "reason"
    for text in ("Rack no longer matches move", "Expected {} board cells, got {}", "{error:?}")
}


def check(doc=DOC, api=API, handler=HANDLER, state=STATE, unreachable=None, with_format=True):
    """Run the script's main() on a tree of these sources, and return (exit, output)."""
    spec = importlib.util.spec_from_file_location("check_api_errors", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "crates" / "server-game" / "src"
        (src / "app").mkdir(parents=True)
        (src / "app" / "games.rs").write_text(handler)
        (src / "app" / "error.rs").write_text(ERROR)
        (src / "game_state.rs").write_text(state)
        (root / "crates" / "api" / "src").mkdir(parents=True)
        (root / "crates" / "api" / "src" / "lib.rs").write_text(api)
        (root / "docs").mkdir()
        (root / "docs" / "4.4.3-api-schema.md").write_text(doc)
        module.ROOT, module.SRC = root, src
        module.API = root / "crates" / "api" / "src" / "lib.rs"
        module.DOC = root / "docs" / "4.4.3-api-schema.md"
        module.FORMAT = root / "format.rs"
        if with_format:
            module.FORMAT.write_text(FORMAT)
        module.UNREACHABLE = unreachable or {}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = module.main()
    return status, out.getvalue()


class CheckApiErrors(Cases):

    def test_it_is_silent_when_the_code_and_the_document_agree(self):
        """a gate prints nothing and exits 0 when there is nothing to say"""
        self.expect("agreeing", (0, ""), check())

    def test_what_it_finds(self):
        """a message is reported when the document has no line for it"""
        no_messages = DOC.split("| | |")[0]
        status, out = check(no_messages)
        self.expect("exit", 1, status)
        for name, message in [
            ("built with format!", "No player named"),
            ("a comment before the literal", "This seat belongs to a different player"),
            ("a sign-in helper's sentence", "Sign in to start a game"),
            ("a constant", "Something went wrong on the server."),
            ("a Refusal::new", "The game has already started"),
            ("refusal! with an argument", "It is not seat"),
            ("refusal! in a closure", "Unknown seat"),
            ("the move rules", "Incorrect tile placement."),
        ]:
            with self.subTest(name):
                self.assertIn(message, out)
        self.expect("the code under cfg(test) is not an interface", False,
                    "only a test asserts" in out)

    def test_a_message_must_sit_under_its_reason(self):
        """the line names the reason, or the message is documented under the wrong one"""
        status, out = check(DOC.replace("| `NOT_YOUR_SEAT` **403**", "| `GAME_NOT_FOUND` **403**"))
        self.expect("wrong reason", 1, status)
        self.assertIn("names no NOT_YOUR_SEAT", out)
        self.assertIn("GAME_NOT_FOUND", out)
        status, out = check(DOC.replace("`The game has already started` | `GAME_NOT_WAITING` **400**",
                                        "`The game has already started` | **400**"))
        self.expect("no reason", 1, status)
        self.assertIn("names no GAME_NOT_WAITING", out)

    def test_a_message_must_state_its_status(self):
        """the status is in bold on the line, and the enum's is the one it must be"""
        status, out = check(DOC.replace("`NOT_YOUR_SEAT` **403**", "`NOT_YOUR_SEAT` **404**"))
        self.expect("wrong status", 1, status)
        self.assertIn("states no **403**", out)
        status, out = check(DOC.replace("`NOT_YOUR_SEAT` **403**", "`NOT_YOUR_SEAT`"))
        self.expect("no status", 1, status)
        self.assertIn("states no **403**", out)

    def test_every_reason_needs_a_row(self):
        """a reason in the enum and not in the Reasons table fails, and so does the reverse"""
        row = "| `UNKNOWN_SEAT` | **400** | business | no | Fix it | a line |\n"
        status, out = check(DOC.replace(row, ""))
        self.expect("missing row", 1, status)
        self.assertIn("UNKNOWN_SEAT", out)
        self.assertIn("no row in the Reasons table", out)
        status, out = check(DOC.replace(row, row + "| `GAME_OVER` | **400** | business | no | Fix it | a line |\n"))
        self.expect("extra row", 1, status)
        self.assertIn("GAME_OVER, which is not a Reason", out)
        status, out = check(DOC.replace("### Reasons", "### Causes"))
        self.expect("no table", 1, status)
        self.assertIn("no `### Reasons` table", out)

    def test_a_reasons_row_agrees_with_the_enum(self):
        """status, type and blip are the enum's, and a row with no status is a failure"""
        row = "| `GAME_NOT_FOUND` | **404** | business | no |"
        for name, changed, expected in [
            ("status", row.replace("**404**", "**400**"), "says status 400, the enum says 404"),
            ("type", row.replace("business", "technical"), "says type 'technical', the enum says 'business'"),
            ("blip", row.replace("| no |", "| yes |"), "says blip 'yes', the enum says 'no'"),
            ("no status", row.replace("**404**", "see below"), "states no status"),
        ]:
            with self.subTest(name):
                status, out = check(DOC.replace(row, changed))
                self.expect("exit", 1, status)
                self.assertIn(expected, out)

    def test_the_status_table_carries_the_enums_type(self):
        """the Type column of the status table is the type of every reason answering it"""
        status, out = check(DOC.replace("| `403` | Forbidden | business |", "| `403` | Forbidden | technical |"))
        self.expect("wrong type", 1, status)
        self.assertIn("the status table gives 403 the type 'technical'; NOT_YOUR_SEAT is 'business'", out)
        status, out = check(DOC.replace("| `404` | Not Found | business | No such thing | Nothing |\n", ""))
        self.expect("a status with no row", 1, status)
        self.assertIn("answers 404, which has no row in the status table", out)

    def test_the_enum_and_its_class_agree(self):
        """a variant with no arm, and an arm with no variant, fail before any document is read"""
        status, out = check(api=API.replace("            Self::Internal => (500, ErrorType::Unexpected, false),\n", ""))
        self.expect("no arm", 1, status)
        self.assertIn("Reason::Internal has no arm in Reason::class", out)

    def test_the_move_rules_text_is_a_source(self):
        """what format_move_error returns reaches a caller, as MOVE_REFUSED, so it is read"""
        status, out = check(DOC.replace("`Incorrect tile placement.`", "`Something else.`"))
        self.expect("changed", 1, status)
        self.assertIn("Incorrect tile placement.", out)
        self.expect("the verb words are not messages", False, "  is " in out or " is'" in out)

    def test_a_named_unreachable_guard_is_not_reported(self):
        """a guard no caller reaches is named with a reason, and only then left out"""
        state = STATE.replace("#[cfg(test)]", GUARDS + "\n#[cfg(test)]")
        status, out = check(state=state, unreachable=NAMED)
        self.expect("named", (0, ""), (status, out))
        status, out = check(state=state)
        self.expect("unnamed", 1, status)
        for message in ("Rack no longer matches move", "Expected {} board cells", "{error:?}"):
            self.assertIn(message, out)

    def test_a_defect_is_documented_as_the_one_500_sentence_under_its_reason(self):
        """Refusal::defect answers INTERNAL_MESSAGE, so its reason needs a line saying so"""
        state = STATE.replace(
            "#[cfg(test)]",
            'fn d() { Refusal::defect(Reason::NotYourTurn, format!("{error:?}")); }\n#[cfg(test)]',
        )
        status, out = check(state=state)
        self.expect("undocumented", 1, status)
        self.assertIn("Something went wrong on the server.", out)
        self.assertIn("names no NOT_YOUR_TURN", out)
        line = "| `Something went wrong on the server.` | `NOT_YOUR_TURN` **400** |\n"
        self.expect("documented", (0, ""), check(DOC + line, state=state))

    def test_a_stale_exclusion_fails(self):
        """an exclusion the scan no longer finds would hide whatever takes its place"""
        status, out = check(unreachable={("game_state.rs", "A message long gone", "MoveRefused"): "reason"})
        self.expect("an UNREACHABLE key not found", (1, True), (status, "STALE" in out))
        status, out = check(with_format=False)
        self.expect("format.rs missing", (1, True), (status, "format.rs not found" in out))

    def test_an_unreachable_guard_is_named_by_file_and_reason(self):
        """the same words, reachable from another file or reason, are still held to the document"""
        handler = HANDLER + 'fn h() { ApiProblem::new(Reason::MoveRefused, "Rack no longer matches move"); }'
        state = STATE.replace("#[cfg(test)]", GUARDS + "\n#[cfg(test)]")
        status, out = check(handler=handler, state=state, unreachable=NAMED)
        self.expect("games.rs still reported", (1, True), (status, "Rack no longer matches move" in out))

    def test_a_constructor_it_does_not_read_stops_it(self):
        """a per-status constructor would pass unseen, so it is a failure of its own"""
        handler = HANDLER + "fn h() { Err(ApiProblem::not_found(\"Gone\"))?; }"
        status, out = check(handler=handler)
        self.expect("unread constructor", (1, True), (status, "STALE" in out and "ApiProblem::not_found" in out))

    def test_a_reason_the_enum_lacks_fails(self):
        """a message under a reason that is not a variant is reported, not skipped"""
        handler = HANDLER + 'fn h() { ApiProblem::new(Reason::Gone, "It went"); }'
        status, out = check(handler=handler)
        self.expect("unknown reason", (1, True), (status, "Reason::Gone, which is not in the enum" in out))


if __name__ == "__main__":
    unittest.main()
