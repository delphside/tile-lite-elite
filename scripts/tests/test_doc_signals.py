"""doc-signals.py: the phrases that mark history in a numbered document. #427 R8.

The cases are docs/5.4's rule, not the patterns: a dated quotation, a dated
change and a design note's headings are history; a date qualifying a
measurement, or the same words inside a code block, are not.
"""

import importlib.util
import unittest
from pathlib import Path

from board.tests.cases import Cases
from board.tests.cli import run

SPEC = importlib.util.spec_from_file_location(
    "doc_signals", Path(__file__).resolve().parents[1] / "doc-signals.py")
signals = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signals)


def count(text):
    return len(signals.matches(text))


class DocSignals(Cases):
    def test_history_is_counted(self):
        self.expect("an owner quotation with its date", 1,
                    count('Owner, 2026-09-21: *"keep it"*'))
        self.expect("an owner quotation without a date", 1,
                    count('Owner: *"accounts and people"*'))
        self.expect("a dated change", 1, count("Corrected 2026-09-07. This said"))
        self.expect("until a date", 1, count("It answered 400 until 2026-09-21."))
        self.expect("a dated change in lower case", 1,
                    count("Issues #188 to #213 were deleted on 2026-09-10."))
        self.expect("a design note's heading", 1, count("## Next Steps"))
        self.expect("a line counts once, whatever it carries", 1,
                    count("Owner, 2026-09-21: until 2026-09-22, next steps"))

    def test_current_truth_is_not(self):
        self.expect("a measurement's date", 0,
                    count("Measured 2026-08-11 against sowpods.txt"))
        self.expect("the owner as a role", 0,
                    count("the owner reviews it monthly"))
        self.expect("a code block", 0,
                    count("```text\nOwner, 2026-09-21: *\"x\"*\n```"))
        self.expect("plain prose", 0, count("A release always takes a semver."))

    def test_the_command_reports_and_never_fails(self):
        result = run("doc-signals.py", "--total")
        self.expect("exit status", 0, result.returncode)
        self.expect("a number", True, result.stdout.strip().isdigit())

    def test_the_log_and_the_map_are_exempt(self):
        names = {p.name for p in signals.documents()}
        self.expect("the delivery log", False, "5.6-delivery-log.md" in names)
        self.expect("the generated map", False, "1.6-document-map.md" in names)
        self.expect("a numbered document", True, "5.1-change-lifecycle.md" in names)


if __name__ == "__main__":
    unittest.main()
