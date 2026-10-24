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


def check(doc, handler=HANDLER, state=STATE):
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
        self.expect("all documented", (0, True), (lambda r: (r[0], "all 5 error messages" in r[1]))(check(DOC)))

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


if __name__ == "__main__":
    unittest.main()
