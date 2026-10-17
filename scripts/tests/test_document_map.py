"""document-map.py and the document numbering: three levels, R.1 to R.4.

An application's documents are `R.G.N` in the programme's one numbering, R its
document range: R.1 overview, R.2 design, R.3 development and operation, R.4
reference. The cases are that scheme (docs/README.md), not the code: a name
outside it is refused, the order is numeric at every level, and the map is the
document the scheme numbers R.1.6. R is the fake application's, 9, from its
programme profile (`board/tests/fixtures`), and the map's path is its technical
profile's.
"""

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

from board.tests.cases import Cases
from board.tests.cli import run

SPEC = importlib.util.spec_from_file_location(
    "document_map", Path(__file__).resolve().parents[1] / "programme" / "docs" / "document-map.py")
docmap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(docmap)


def make_application(top: Path, names=("9.1.1-overview.md", "9.3.2-development.md", "README.md")) -> Path:
    """A git repository with a docs/ folder holding these documents."""
    subprocess.run(["git", "init", "-q", str(top)], check=True)
    (top / "docs").mkdir()
    for name in names:
        (top / "docs" / name).write_text(f"# {name}\n\nFirst sentence of {name}.\n\n## Section of {name}\n")
    return top


class Numbering(Cases):
    def test_a_three_level_name_in_the_range_is_accepted(self):
        for name in ("9.1.0-rules.md", "9.2.7-authentication-and-invitations.md",
                     "9.3.10-benchmarking.md", "9.4.7-log-events.md"):
            self.expect(name, [], docmap.misnamed([Path(name)]))

    def test_a_name_outside_the_scheme_is_refused(self):
        for name, why in (("3.3-testing-ci-and-release.md", "the old two-level number"),
                          ("9.3-api-schema.md", "two levels in the 9.x range"),
                          ("9.5.1-anything.md", "a group the range does not have"),
                          ("4.1.1-architecture.md", "another application's range, which the real one is"),
                          ("9.3.10benchmarking.md", "no hyphen after the number")):
            self.expect(why, [Path(name)], docmap.misnamed([Path(name)]))

    def test_the_index_is_not_numbered(self):
        self.expect("README", [], docmap.misnamed([Path("README.md")]))

    def test_order_is_numeric_at_every_level(self):
        names = ["9.3.10-b.md", "9.3.2-b.md", "9.4.1-b.md", "9.1.6-b.md", "9.3.3-b.md"]
        self.expect("order", ["9.1.6-b.md", "9.3.2-b.md", "9.3.3-b.md", "9.3.10-b.md", "9.4.1-b.md"],
                    sorted(names, key=docmap.number_key))

    def test_the_documents_of_an_application_are_all_in_the_scheme(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = make_application(Path(tmp) / "widget")
            self.expect("the command", 0, run("programme/docs/document-map.py", "--names", cwd=app).returncode)

    def test_a_document_outside_the_scheme_fails_the_command_and_names_the_range(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = make_application(Path(tmp) / "widget", ("9.1.1-overview.md", "4.1.1-architecture.md"))
            result = run("programme/docs/document-map.py", "--names", cwd=app)
            self.expect("exit status", 1, result.returncode)
            self.expect("names the document", True, "4.1.1-architecture.md" in result.stderr)
            self.expect("and the range it wanted", True, "expected 9.G.N-name.md" in result.stderr)


class TheMap(Cases):
    def test_the_map_is_where_the_technical_profile_says(self):
        self.expect("file", "9.1.6-document-map.md", docmap.OUT.name)
        with tempfile.TemporaryDirectory() as tmp:
            app = make_application(Path(tmp) / "widget")
            written = run("programme/docs/document-map.py", "--write", cwd=app)
            self.expect("writes", 0, written.returncode)
            text = (app / "docs" / "9.1.6-document-map.md").read_text()
            self.expect("title", "# 9.1.6 Document map", text.splitlines()[0])
            self.expect("it does not list itself", False, "[9.1.6-document-map.md]" in text)
            self.expect("it lists the others", True, "[9.1.1-overview.md]" in text)
            self.expect("it links the programme file's repository", True,
                        "https://github.com/fakeorg/fake-programme/blob/main/docs/1.5-writing-documents.md" in text)

    def test_it_is_current_after_it_is_written_and_stale_after_a_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = make_application(Path(tmp) / "widget")
            self.expect("absent is stale", 1, run("programme/docs/document-map.py", "--check", cwd=app).returncode)
            run("programme/docs/document-map.py", "--write", cwd=app)
            self.expect("current", 0, run("programme/docs/document-map.py", "--check", cwd=app).returncode)
            (app / "docs" / "9.1.1-overview.md").write_text("# new\n\n## Another\n")
            self.expect("stale", 1, run("programme/docs/document-map.py", "--check", cwd=app).returncode)


if __name__ == "__main__":
    unittest.main()
