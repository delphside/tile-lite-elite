"""the dateless Gantt, R8.

The picture is only as good as what it chooses to draw, so what is tested is
the choosing: which issues get a bar, what a dependency on a parent means,
and where a bar sits when nothing sequences it. No network: canned issues.

  bars          deliveries only — a parent makes none, so it has none
  lifting       blocked by a parent means blocked by every delivery it makes
  columns       longest path, and 0 when nothing blocks it
  cycles        reported, not recursed into"""

import unittest

from .cases import Cases

from board.model import RawIssue, RawSubIssue
from board.roadmap import BAR_H, build, draw
from board.sources import Snapshot


def issue(number, kind="Project", subs=(), parent=None, ws="W",
          milestone=None, blocked_by=()):
    return RawIssue(number, f"issue {number}", "OPEN", "", kind,
                    {"Workstream": ws, "Phase": "Q1"}, tuple(subs), parent,
                    milestone, frozenset(), frozenset(blocked_by), frozenset())

def road(*raws, **kw):
    return build(Snapshot(tuple(raws), 0.0, 0.0, 1, False), **kw)

def drawn(r):
    return sorted(i.number for lane in r.lanes.values() for i in lane)

import re as _re


class TheRoadmap(Cases):

    def test_a_bar_is_a_delivery_a_parent_makes_none_so_it_has_none(self):
        """a bar is a delivery: a parent makes none, so it has none"""
        r = road(
            issue(71, subs=[RawSubIssue(268, "Project"), RawSubIssue(269, "Project")]),
            issue(268, parent=71), issue(269, parent=71),
            issue(9),                                   # standalone: carries a milestone
            issue(5, kind="Requirement"), issue(6, kind="Decision"),
            issue(7, kind="PullRequest"),
        )
        self.expect("parent has no bar, its packages and a standalone do", [9, 268, 269], drawn(r))

    def test_blocked_by_a_parent_means_blocked_by_every_delivery_it_makes(self):
        """blocked by a parent means blocked by every delivery it makes"""
        r = road(
            issue(71, subs=[RawSubIssue(268, "Project"), RawSubIssue(269, "Project")]),
            issue(268, parent=71), issue(269, parent=71),
            issue(10, blocked_by=[71]),
        )
        self.expect("one recorded dependency becomes two arrows",
              [(268, 10), (269, 10)], r.edges)
        self.expect("and is reported as lifted, not silently multiplied",
              [(71, 10)], sorted({(b, i) for b, i, _ in r.lifted}))
        self.expect("the blocked bar sits one column right", 1, r.rank[10])
        self.expect("its blockers start at the left", [0, 0], [r.rank[268], r.rank[269]])

    def test_a_parent_s_own_blocker_reaches_its_packages_too(self):
        """a parent's own blocker reaches its packages too"""
        r = road(
            issue(71, subs=[RawSubIssue(268, "Project")], blocked_by=[9]),
            issue(268, parent=71), issue(9),
        )
        self.expect("blocking a parent blocks its deliveries", [(9, 268)], r.edges)

    def test_columns_are_the_longest_path_so_a_chain_spreads_out(self):
        """columns are the longest path, so a chain spreads out"""
        r = road(issue(1), issue(2, blocked_by=[1]), issue(3, blocked_by=[1, 2]))
        self.expect("a three-link chain occupies three columns",
              [0, 1, 2], [r.rank[1], r.rank[2], r.rank[3]])
        self.expect("nothing recorded means column 0", 1, r.unsequenced)

    def test_unsequenced_is_the_normal_case_and_is_counted_not_hidden(self):
        """unsequenced is the normal case and is counted, not hidden"""
        r = road(issue(1), issue(2), issue(3))
        self.expect("three bars, none sequenced", 3, r.unsequenced)
        self.expect("and no arrows invented", [], r.edges)

    def test_a_cycle_is_reported_rather_than_recursed_into(self):
        """a cycle is reported rather than recursed into"""
        r = road(issue(1, blocked_by=[2]), issue(2, blocked_by=[1]))
        self.expect("both still get a column", 2, len(r.rank))
        self.expect("and the cycle is named", True, bool(r.cycles))

    def test_swimlanes_are_workstreams_and_unset_is_its_own_lane(self):
        """swimlanes are workstreams, and unset is its own lane"""
        r = road(issue(1, ws="Client UI"), issue(2, ws="Game Rules"),
                 issue(3, ws=None))
        self.expect("one lane per workstream, unset last",
              ["Client UI", "Game Rules", "no workstream set"], list(r.lanes))

    def test_the_drawing_says_what_it_drew(self):
        """the drawing says what it drew"""
        r = road(issue(1, ws="Client UI", milestone="0.8.1"), issue(2, blocked_by=[1]))
        text = draw(r)
        self.expect("a bar carries its milestone", True, "0.8.1" in text)
        self.expect("a missing milestone is visible, not blank", True, "milestone not set" in text)
        self.expect("the swimlane is labelled", True, "Client UI" in text)
        self.expect("it is SVG, because Mermaid cannot do swimlanes", True,
              text.startswith("<svg ") and text.rstrip().endswith("</svg>"))
        self.expect("the axis is ordinal, not dated", True, "can start now" in text)
        self.expect("a second column appears once something is sequenced",
              True, "after 1 round" in text)
        # GitHub strips these from an SVG in markdown, so using any of them would
        # render a blank or broken chart for everyone but the author.
        for banned in ("<style", "<defs", "<marker", "foreignObject", "<script"):
            self.expect(f"nothing the sanitiser strips: {banned}", False, banned in text)
        self.expect("an arrow is drawn for the dependency", True, "<polygon" in text)

    def test_a_bar_is_one_width_because_width_would_imply_duration(self):
        """a bar is one width, because width would imply duration"""
        r = road(issue(1), issue(2, blocked_by=[1]))
        widths = _re.findall(rf'<rect [^>]*width="(\d+)" height="{BAR_H}"', draw(r))
        self.expect("both bars the same width", 1, len(set(widths)))


    def test_a_work_package_names_its_parent_project(self):
        """a work package names its parent project; a standalone has none"""
        parent = RawIssue(291, "#291 MAIN PROJECT: Capacity planning", "OPEN", "",
                          "Project", {"Workstream": "W", "Phase": "Q1"},
                          (RawSubIssue(408, "Project"),), None, None,
                          frozenset(), frozenset(), frozenset())
        text = draw(road(parent, issue(408, parent=291), issue(9)))
        self.expect("the package's bar carries the parent's number and name",
                    True, "part of #291 Capacity planning" in text)
        self.expect("the parent's title prefix is not repeated", False,
                    "MAIN PROJECT" in text)
        self.expect("only the one package says so", 1, text.count("part of #"))

    def test_the_colours_have_a_key(self):
        """the colours have a key: each band, and the phases it covers"""
        text = draw(road(issue(1)))
        for band, phase in (("planned", "Scope"), ("designing", "Design and Test Approach"),
                            ("building", "Development"), ("landed", "Post-deployment")):
            self.expect(f"the key names {band}", True, f">{band}" in text)
            self.expect(f"and a phase it covers, {phase}", True, phase in text)


if __name__ == "__main__":
    unittest.main()

