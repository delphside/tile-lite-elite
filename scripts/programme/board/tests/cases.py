"""The one assertion the suites moved from `scripts/tests/` were written in."""

import unittest


class Cases(unittest.TestCase):
    """A test method holds a section of named cases. Each is a subTest, so one
    failing case is reported by name and the rest of the section still runs."""

    def expect(self, name, want, got):
        with self.subTest(name):
            self.assertEqual(want, got)
