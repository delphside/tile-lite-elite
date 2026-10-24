"""check-api-errors.py: the messages it finds, and the status it compares, #529.

The check said all 72 messages were documented while about 25 were not, because
it matched only `ApiProblem::x("literal"`. Each case here is a message the first
version could not see, or a status it never looked at, built into a small source
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

HANDLER = '''
fn handler() -> Result<(), ApiProblem> {
    Err(ApiProblem::not_found(format!("No player named '{name}'")))?;
    Err(ApiProblem::forbidden(
        // the guard, not the game
        "This seat belongs to a different player",
    ))?;
    game.start().map_err(ApiProblem::bad_request)?;
    Ok(())
}
'''

STATE = '''
fn start(&mut self) -> Result<(), String> {
    if self.started {
        return Err("The game has already started".to_string());
    }
    let seat = self.seat(n).ok_or_else(|| format!("Unknown seat {n}"))?;
    Err(format!("It is not seat {seat_number}'s turn"))
}

#[cfg(test)]
mod tests {
    fn t() { Err("A message only a test asserts".to_string()) }
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
fn guards() -> Result<(), String> {
    return Err("Rack no longer matches move".to_string());
    return Err(format!("Expected {} board cells, got {}", a, b));
    x.map_err(|error| format!("{error:?}"))?;
}
'''


def check(doc, handler=HANDLER, state=STATE, unreachable=None, passed_on=None, with_format=True):
    """Run the script's main() on a tree of these sources, and return (exit, output)."""
    spec = importlib.util.spec_from_file_location("check_api_errors", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        src = root / "crates" / "server-game" / "src"
        (src / "app").mkdir(parents=True)
        (src / "app" / "games.rs").write_text(handler)
        (src / "game_state.rs").write_text(state)
        (root / "docs").mkdir()
        (root / "docs" / "4.4.3-api-schema.md").write_text(doc)
        module.ROOT, module.SRC = root, src
        module.DOC = root / "docs" / "4.4.3-api-schema.md"
        module.STATE = src / "game_state.rs"
        module.FORMAT = root / "format.rs"
        if with_format:
            module.FORMAT.write_text(FORMAT)
        module.PASSED_ON = passed_on or {}
        module.UNREACHABLE = unreachable or {}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = module.main()
    return status, out.getvalue()


# How 4.4.3 writes them: a variable part as `<x>`, `N`, `{error}`; a status in bold.
DOC = """
| `No player named '<x>'` | **404**. A `named` claim whose player does not exist |
| `This seat belongs to a different player` | **403** |
| `The game has already started` | **400** |
| `Unknown seat <n>` | **400** |
| `It is not seat N's turn` | **400** |
| `<words> is/are not in the dictionary.` · `Incorrect tile placement.` | **400** |
"""


class CheckApiErrors(Cases):

    def test_what_it_finds(self):
        """a message the first version could not see is reported when undocumented"""
        for name, message in [
            ("built with format!", "No player named"),
            ("a comment before the literal", "This seat belongs to a different player"),
            ("an Err(String) from the game", "The game has already started"),
            ("a format! Err(String)", "It is not seat"),
            ("an ok_or_else String", "Unknown seat"),
        ]:
            with self.subTest(name):
                status, out = check("nothing is documented here\n")
                self.assertEqual(1, status)
                self.assertIn(message, out)
        self.expect("the code under cfg(test) is not an interface", False,
                    "only a test asserts" in check("")[1])

    def test_a_placeholder_is_a_wildcard(self):
        """the fixed text is matched against how the document writes the variable part"""
        self.expect("all documented", (0, True), (lambda r: (r[0], "all 7 error messages" in r[1]))(check(DOC)))

    def test_it_compares_the_status(self):
        """a message under the wrong status fails, and the report says what the document says"""
        status, out = check(DOC.replace("**404**", "**400**"))
        self.expect("wrong status", 1, status)
        self.assertIn("404 No player named", out)
        self.assertIn("4.4.3 says 400", out)
        # An exchange the handler passes through bad_request is a 400, whatever it says.
        status, out = check(DOC.replace("`The game has already started` | **400**",
                                        "`The game has already started` | **403**"))
        self.expect("a passed-on Err(String) is a 400", 1, status)
        self.assertIn("4.4.3 says 403", out)

    def test_a_line_with_no_status_is_not_a_mismatch(self):
        """silence is how the document writes the usual status, so only the words are checked"""
        status, out = check(DOC.replace(" | **400**", " | fewer than two"))
        self.expect("exit", 0, status)
        self.assertIn("no status", out)

    def test_the_move_rules_text_is_a_source(self):
        """what format_move_error returns reaches a caller as a 400, so it is read"""
        status, out = check("nothing is documented here\n")
        for message in ("not in the dictionary.", "Incorrect tile placement."):
            self.assertIn(message, out)
        self.expect("the verb words are not messages", False, "  is " in out or " 400 is " in out)
        self.expect("documented as 4.4.3 writes it", 0, check(DOC)[0])

    def test_a_named_unreachable_guard_is_not_reported(self):
        """a guard no caller reaches is named with a reason, and only then left out"""
        state = STATE.replace("#[cfg(test)]", GUARDS + "\n#[cfg(test)]")
        named = {("game_state.rs", text, 400): "reason" for text in (
            "Rack no longer matches move", "Expected {} board cells, got {}", "{error:?}")}
        status, out = check(DOC, state=state, unreachable=named)
        self.expect("named", 0, status)
        self.expect("rack guard", False, "Rack no longer" in out)
        self.expect("board_from_dto", False, "board cells" in out)
        self.expect("a placeholder-only format is named too", False, "{error:?}" in out)
        # The same tree with nothing named is red: each guard, and the one made only of placeholders.
        status, out = check(DOC, state=state)
        self.expect("unnamed", 1, status)
        for message in ("Rack no longer matches move", "Expected {} board cells", "{error:?}"):
            self.assertIn(message, out)

    def test_a_stale_exclusion_fails(self):
        """an exclusion the scan no longer finds would hide whatever takes its place"""
        status, out = check(DOC, unreachable={("game_state.rs", "A message long gone", 400): "reason"})
        self.expect("an UNREACHABLE key not found", (1, True), (status, "STALE" in out))
        status, out = check(DOC, passed_on={("app/games.rs", "internal"): ("text from elsewhere", 500)})
        self.expect("a PASSED_ON name with no pass-through", (1, True), (status, "STALE" in out))
        status, out = check(DOC, with_format=False)
        self.expect("format.rs missing", (1, True), (status, "format.rs not found" in out))

    def test_an_unreachable_guard_is_named_by_file(self):
        """the same words, reachable from another file, are still held to the document"""
        handler = HANDLER + 'fn h() { ApiProblem::bad_request("Rack no longer matches move"); }'
        state = STATE.replace("#[cfg(test)]", GUARDS + "\n#[cfg(test)]")
        named = {("game_state.rs", text, 400): "reason" for text in (
            "Rack no longer matches move", "Expected {} board cells, got {}", "{error:?}")}
        status, out = check(DOC, handler=handler, state=state, unreachable=named)
        self.expect("games.rs still reported", (1, True), (status, "Rack no longer matches move" in out))

    def test_a_bare_pass_through_must_be_named(self):
        """map_err(ApiProblem::internal) passes text the scan cannot read, so each is named"""
        handler = HANDLER + "fn h() { x.map_err(ApiProblem::internal)?; }"
        status, out = check(DOC, handler=handler)
        self.expect("unnamed", (1, True), (status, "STALE" in out and "app/games.rs" in out))
        named = {("app/games.rs", "internal"): ("the hashing library's own error text", 500)}
        status, out = check(DOC + "| `the hashing library's own error text` | **500** |\n", handler=handler, passed_on=named)
        self.expect("named", 0, status)


if __name__ == "__main__":
    unittest.main()
