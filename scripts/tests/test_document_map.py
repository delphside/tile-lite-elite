"""document-map.py and the document numbering: three levels, 4.1 to 4.4.

Tile Lite Elite's documents are `4.G.N` in the programme's one numbering: 4.1
overview, 4.2 design, 4.3 development and operation, 4.4 reference. The cases
are that scheme (docs/README.md), not the code: a name outside it is refused,
the order is numeric at every level, and the map is the document the scheme
numbers 4.1.6.
"""

import importlib.util
import unittest
from pathlib import Path

from board.tests.cases import Cases
from board.tests.cli import run

SPEC = importlib.util.spec_from_file_location(
    "document_map", Path(__file__).resolve().parents[1] / "programme" / "docs" / "document-map.py")
docmap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(docmap)


class Numbering(Cases):
    def test_a_three_level_name_in_the_range_is_accepted(self):
        for name in ("4.1.0-rules.md", "4.2.7-authentication-and-invitations.md",
                     "4.3.10-benchmarking.md", "4.4.7-log-events.md"):
            self.expect(name, [], docmap.misnamed([Path(name)]))

    def test_a_name_outside_the_scheme_is_refused(self):
        for name, why in (("3.3-testing-ci-and-release.md", "the old two-level number"),
                          ("4.3-api-schema.md", "two levels in the 4.x range"),
                          ("4.5.1-anything.md", "a group the range does not have"),
                          ("5.1.1-architecture.md", "another application's range"),
                          ("4.3.10benchmarking.md", "no hyphen after the number")):
            self.expect(why, [Path(name)], docmap.misnamed([Path(name)]))

    def test_the_index_is_not_numbered(self):
        self.expect("README", [], docmap.misnamed([Path("README.md")]))

    def test_order_is_numeric_at_every_level(self):
        names = ["4.3.10-b.md", "4.3.2-b.md", "4.4.1-b.md", "4.1.6-b.md", "4.3.3-b.md"]
        self.expect("order", ["4.1.6-b.md", "4.3.2-b.md", "4.3.3-b.md", "4.3.10-b.md", "4.4.1-b.md"],
                    sorted(names, key=docmap.number_key))

    def test_the_documents_of_this_repository_are_all_in_the_scheme(self):
        self.expect("misnamed", [], docmap.misnamed(sorted(docmap.DOCS.glob("*.md"))))
        self.expect("the command", 0, run("programme/docs/document-map.py", "--names").returncode)


class TheMap(Cases):
    def test_the_map_is_4_1_6(self):
        self.expect("file", "4.1.6-document-map.md", docmap.OUT.name)
        text, _files = docmap.build()
        self.expect("title", "# 4.1.6 Document map", text.splitlines()[0])
        self.expect("it does not list itself", False, "[4.1.6-document-map.md]" in text)

    def test_it_is_current(self):
        self.expect("exit status", 0, run("programme/docs/document-map.py", "--check").returncode)


if __name__ == "__main__":
    unittest.main()
