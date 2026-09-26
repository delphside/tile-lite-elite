"""D54's weekly digest, #382.

The digest exists to hold me to a limit, so the cases that matter are the
ones where a bug would flatter the report:

  direction     a share that is not falling must say so, not round kindly
  threshold     45% and the 2026-10-17 horizon stand as PROPOSED — the owner
                was asked to confirm them and has not, and an unconfirmed
                number must not harden into a fact by being repeated
  judgement     "anything I decided that you might have decided differently"
                cannot be derived; an empty section must say it was not
                written, never that there was nothing

No network and no git: canned counts only."""

import unittest

from .cases import Cases

import collections
from board.digest import Digest, render, THRESHOLD, MEASURED_AT


def digest(tooling, total, **kw):
    d = Digest(since="2026-09-17", until="HEAD", tooling=tooling, total=total, **kw)
    d.by_type = collections.Counter({"tooling": tooling, "other": total - tooling})
    return d



class TheDigest(Cases):

    def test_the_share_is_arithmetic_and_the_direction_is_honest_about_it(self):
        """the share is arithmetic, and the direction is honest about it"""
        self.expect("below the threshold", True, "below" in digest(4, 10).direction)
        self.expect("falling but not there yet", True, "falling" in digest(48, 100).direction)
        # 55% is where D54 measured it. Anything at or above that is not falling, and
        # the digest must not describe it as progress.
        self.expect("not falling is said plainly", True, "not falling" in digest(55, 100).direction)
        self.expect("worse than when it started is also not falling",
              True, "not falling" in digest(70, 100).direction)
        self.expect("the share rounds down, never up", 48, digest(48, 100).share)
        self.expect("no issues at all does not divide by zero", 0, digest(0, 0).share)

    def test_an_unconfirmed_threshold_is_repeated_as_unconfirmed(self):
        """an unconfirmed threshold is repeated as unconfirmed"""
        text = render(digest(48, 100))
        self.expect("the threshold appears", True, f"{THRESHOLD}%" in text)
        self.expect("and is marked as standing only as proposed",
              True, "stand as proposed" in text)
        self.expect("the measured starting point is not lost", True, str(MEASURED_AT) in text)

    def test_what_cannot_be_derived_is_not_reported_as_nothing(self):
        """what cannot be derived is not reported as nothing"""
        self.expect("an unwritten judgement section says so",
              True, "was not written" in render(digest(48, 100)))
        self.expect("and does not claim there was nothing",
              False, "nothing to report" in render(digest(48, 100)))
        written = render(digest(48, 100), ["I left status.sh alone"])
        self.expect("a supplied judgement is shown", True, "I left status.sh alone" in written)
        self.expect("and the disclaimer goes away", False, "was not written" in written)

    def test_deletion_is_reported_even_when_it_is_zero_because_that_is_the_poi(self):
        """deletion is reported even when it is zero, because that is the point"""
        # D54: "removing tooling is as much in scope as adding it, and needs no more
        # permission" — so a week that added 4000 lines and removed none must say it.
        plain = render(digest(48, 100, lines_added=4174, lines_removed=334))
        self.expect("nothing removed is stated, not omitted",
              True, "Nothing was removed this week." in plain)
        self.expect("the line counts appear", True, "4174 lines added, 334 removed" in plain)
        some = render(digest(48, 100, files_deleted=["scripts/old.sh"]))
        self.expect("a deleted file is named", True, "`scripts/old.sh`" in some)


if __name__ == "__main__":
    unittest.main()

