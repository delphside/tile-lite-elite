"""Which documents are process documents (#421).

From the rule, owner 2026-09-25: the process documents describe the programme
and change on main; technical documents change with the code; docs/1.6 is
generated and belongs to neither.
"""

import unittest

from .cli import run


def process(*paths: str) -> list[str]:
    return run("board-documents.py", "process", stdin="".join(p + "\n" for p in paths)).stdout.split()


class ProcessDocuments(unittest.TestCase):
    def test_the_three_process_documents_and_nothing_else(self):
        self.assertEqual(
            ["CLAUDE.md", "docs/5.1-change-lifecycle.md", "docs/5.2-workstreams.md"],
            process("CLAUDE.md", "docs/5.1-change-lifecycle.md", "docs/5.2-workstreams.md",
                    "docs/1.6-document-map.md", "docs/4.3-api-schema.md", "scripts/deploy.sh"),
        )

    def test_the_generated_map_is_not_one(self):
        self.assertEqual([], process("docs/1.6-document-map.md"))

    def test_a_technical_document_is_not_one(self):
        self.assertEqual([], process("docs/4.3-api-schema.md"))

    def test_an_unknown_command_is_refused(self):
        self.assertEqual(2, run("board-documents.py", "frobnicate").returncode)


if __name__ == "__main__":
    unittest.main()
