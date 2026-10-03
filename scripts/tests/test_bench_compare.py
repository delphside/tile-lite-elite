"""bench-compare.py: the pairing and the exclusion, against fixtures.

The tool exists because a VM's p99 is not evidence about the code, and it is
only correct if it pairs the *same* positions and excludes on the ratio rather
than on an absolute time. Both are tested here, with a fixture built so that
an absolute-time rule would give the wrong answer.
"""

import re
import tempfile
import unittest
from pathlib import Path

from board.tests.cases import Cases
from board.tests.cli import SCRIPTS, run

H = "run,game,turn,seat,blanks,rack_tiles,wall_ms,cpu_ms"


def write(path, rows):
    path.write_text("\n".join([H, *rows]) + "\n")
    return str(path)


def self_comparison_run(path, first_stall):
    """Ten stalls per run, at turns nothing else stalls on, so with two runs a
    side the polluted fraction is 10% and reaches the p95 and p99. Two stalls
    in 200 positions would sit below the p99 index and the wrong baseline would
    pass unnoticed, which is what the first version of this fixture did."""
    rows = []
    for i in range(200):
        stalled = ((i - first_stall) % 100 == 0 and i >= first_stall) or i == first_stall \
            or i % 20 == first_stall % 20
        rows.append(f"9,0,{i},0,0,7,60.0,0.5" if stalled else f"9,0,{i},0,0,7,1.0,1.0")
    return write(path, rows)


class BenchCompare(Cases):
    def setUp(self):
        self._dir = tempfile.TemporaryDirectory()
        self.addCleanup(self._dir.cleanup)
        self.d = Path(self._dir.name)
        # A genuinely slow position, slow on BOTH machines at a ratio of 2x, must
        # be kept although its absolute time is the largest in the file; an
        # ordinary position the hypervisor sat on, 50x, must be excluded.
        self.ref = write(self.d / "ref.csv", ["1,0,0,0,1,7,40.0,40.0",
                                              *(f"1,0,{i},0,0,7,1.0,1.0" for i in range(1, 99)),
                                              "1,0,99,0,0,7,1.0,1.0"])
        self.sub = write(self.d / "sub.csv", ["2,0,0,0,1,7,80.0,80.0",
                                              *(f"2,0,{i},0,0,7,2.0,2.0" for i in range(1, 99)),
                                              "2,0,99,0,0,7,50.0,0.2"])

    def selves(self):
        x = [self_comparison_run(self.d / f"x{n}.csv", s) for n, s in ((1, 3), (2, 7))]
        y = [self_comparison_run(self.d / f"y{n}.csv", s) for n, s in ((1, 11), (2, 13), (3, 17))]
        return [*x, "--", *y]

    def test_pairing_and_exclusion(self):
        out = run("bench-compare.py", self.ref, self.sub).stdout
        self.expect("pairs every move", True, "paired on (game, turn): 100 moves" in out)
        self.expect("excludes exactly the stalled one", True, "excluded: 1 (1.0%)" in out)
        # The 40 ms move is four times slower in absolute terms than the 50x one
        # is in ratio terms; an absolute-time cut would drop it and report 2.0x.
        self.expect("keeps the slow-on-both position", True,
                    re.search(r"ratio, cleaned:\s+2\.000x\s+2\.000x", out) is not None)
        self.expect("reports the uncleaned ratio too", True, "ratio, all moves" in out)

    def test_refusals(self):
        # Runs of different benchmarks share no positions and must not be compared.
        other = write(self.d / "other.csv", ["3,9,9,0,0,7,1.0,1.0"])
        self.expect("refuses runs with nothing in common", 1, run("bench-compare.py", self.ref, other).returncode)
        self.expect("refuses with no arguments", 2, run("bench-compare.py").returncode)

    def test_the_same_input_compares_as_itself(self):
        # The self-check the method must pass. The median-based baseline scored
        # 0.390x on this and the minimum scores 1.077x: a stall drags a two-run
        # median up with it and escapes rejection, which is invisible until you
        # compare something against itself.
        out = run("bench-compare.py", *self.selves()).stdout
        self.expect("same input compares as 1.0 at every percentile", True,
                    re.search(r"ratio, per-move means:\s+1\.000x\s+1\.000x\s+1\.000x", out) is not None)
        # Three subject runs, ten stalls each, and the count reports the subject side.
        self.expect("the stalls were discarded, not averaged in", True, "30 stalled timings discarded" in out)

    def test_wide(self):
        # The per-move analysis on the row, so statistics are a column.
        wide = self.d / "wide.csv"
        run("bench-compare.py", *self.selves(), "--wide", str(wide))
        lines = wide.read_text().splitlines()
        self.expect("wide file has a row per position", 201, len(lines))
        self.expect("it carries the reduced mean", True, "sub_mean_wall_ms" in lines[0])
        self.expect("it carries the stall count", True, "sub_stalls_dropped" in lines[0])
        self.expect("it carries a column per run", 5, sum("_wall_9" in c for c in lines[0].split(",")))
        # Same input both sides, so every row's ratio is exactly 1.
        self.expect("every row's ratio is 1.0", 200, sum(l.endswith(",1.0000") for l in lines[1:]))

    def test_runs_of_different_things_are_refused_not_merged(self):
        odd = write(self.d / "odd.csv", [f"9,0,{i},0,9,7,1.0,1.0" for i in range(200)])
        x1 = self_comparison_run(self.d / "x1.csv", 3)
        self.expect("refuses runs whose racks disagree", 1,
                    run("bench-compare.py", x1, odd, "--wide", str(self.d / "bad.csv")).returncode)

    def test_is_registered_as_a_tool(self):
        self.expect("is registered as a tool", True,
                    "bench-compare.py" in (SCRIPTS.parent / "docs/3.0-tools.md").read_text())


if __name__ == "__main__":
    unittest.main()
