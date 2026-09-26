"""the dependency advisory check, #297.

Everything here is a way the check could go quietly wrong. A security check
that fails loudly gets fixed; one that passes when it should not is worse
than none, because it is also reassuring.

  pipefail        without it the audit's exit status is `tee`'s, which is
                  always zero, and every run is green forever
  reasons         audit.toml's own header: an entry with no reason is
                  indistinguishable from something nobody looked at
  the printer     what a green run suppressed (#339) — untested because it
                  lives inside the workflow YAML, so extract and run it
  R2's scope      github-actions watched, cargo deliberately not

No network: the repository's own files only."""

import unittest

from board.tests.cases import Cases

import pathlib, re, subprocess, sys, textwrap


ROOT = pathlib.Path(__file__).resolve().parents[2]
wf = (ROOT / ".github/workflows/advisories.yml").read_text()
audit = (ROOT / ".cargo/audit.toml").read_text()
dependabot = (ROOT / ".github/dependabot.yml").read_text()


def quieted():
    """audit.toml's ignored advisories, and those of them with no reason."""
    ids, missing, comment = [], [], []
    inside = False
    for line in audit.splitlines():
        s = line.strip()
        if s.startswith("ignore"):
            inside, comment = True, []
            continue
        if not inside:
            continue
        if s.startswith("]"):
            break
        if s.startswith("#"):
            comment.append(s.lstrip("# ").rstrip())
            continue
        m = re.match(r'"(RUSTSEC-[\d-]+)"', s)
        if m:
            ids.append(m.group(1))
            if not " ".join(comment).strip():
                missing.append(m.group(1))
        if not s:
            comment = []
    return ids, missing



class Advisories(Cases):

    def test_the_audit_s_exit_status_is_the_audit_s_not_tee_s(self):
        """the audit's exit status is the audit's, not tee's"""
        # `cargo audit ... | tee` without pipefail reports tee's status, which is
        # always zero. The check would pass for ever and nobody would see it happen.
        run = re.search(r"name: Audit\b.*?run: \|\n(.*?)\n      - name:", wf, re.S)
        self.expect("the Audit step exists", True, run is not None)
        body = run.group(1) if run else ""
        self.expect("pipefail is set before the pipe", True, "set -o pipefail" in body)
        self.expect("the audit is piped through tee", True, "| tee" in body)
        self.expect("it denies warnings, since severity does not track reachability",
              True, "--deny warnings" in body)

    def test_the_report_is_opened_on_failure_and_a_failing_step_cannot_skip_it(self):
        """the report is opened on failure, and a failing step cannot skip it"""
        # `if: always()` matters: without it the failed audit ends the job and the
        # report never reaches anybody, which is the whole point of the workflow.
        report = re.search(r"name: Open or update the report\n\s*if: ([^\n]+)", wf)
        self.expect("the report step is guarded by always()", True,
              report is not None and "always()" in report.group(1))
        self.expect("and only fires when the audit failed", True,
              report is not None and "outcome == 'failure'" in report.group(1))
        self.expect("the issue it raises carries a type, so rules do not skip it (#361)",
              True, "--type Requirement" in wf)

    def test_every_quieted_advisory_says_why_audit_toml_s_own_rule(self):
        """every quieted advisory says why — audit.toml's own rule"""
        ids, missing = quieted()
        self.expect("the list is not empty", True, len(ids) > 0)
        self.expect("no duplicated ids", len(ids), len(set(ids)))
        self.expect("every entry has a reason", [], missing)

    def test_the_printer_that_says_what_a_green_run_suppressed_339(self):
        """the printer that says what a green run suppressed (#339)"""
        # It lives inside the workflow YAML, where nothing can reach it. Extract and
        # run it, so a change to it is covered like any other code.
        block = re.search(r"python3 - <<'EOF'\n(.*?)\n\s*EOF", wf, re.S)
        self.expect("the printer is found in the workflow", True, block is not None)
        if block:
            src = textwrap.dedent(block.group(1))
            out = subprocess.run([sys.executable, "-c", src], capture_output=True, text=True, cwd=ROOT)
            self.expect("it runs", 0, out.returncode)
            self.expect("it reports every entry", True, f"{len(quieted()[0])} advisories" in out.stdout)
            self.expect("and flags nothing as reasonless", False, "NO REASON RECORDED" in out.stdout)

    def test_the_report_is_readable_not_raw_terminal_output(self):
        """the report is readable, not raw terminal output"""
        # cargo audit writes ANSI to the pipe and tee keeps it. #384 arrived with
        # `^[[0m^[[1m^[[31m` around every field -- legible only to somebody willing to
        # read past it, which is what #297 R3 says a report must not require.
        self.expect("the colour is stripped before the body is written",
              True, "sed -r" in wf and "/tmp/audit.txt" in wf and "[0-9;]*[a-zA-Z]" in wf)
        # GitHub rewrites a real ESC to the literal "^[" on the way in, so #384 could
        # not be cleaned by matching \x1b alone. Both forms are handled.
        self.expect("and the literal ^[ form too", True, r"\^\[" in wf)
        self.expect("and the raw file is not pasted in", False, "cat /tmp/audit.txt" in wf)
        # Run the workflow's OWN line, not a hand-written copy of it: a test that
        # writes its own expression proves only that the test author can write sed.
        line = [l for l in wf.splitlines() if l.strip().startswith("sed -r")][0].strip()
        sample = "\x1b[0m\x1b[1m\x1b[31mCrate:\x1b[0m rustls\n^[[31merror:^[[0m 1 found\n"
        out = subprocess.run(["bash", "-c", line.replace("/tmp/audit.txt", "-")],
                             input=sample, capture_output=True, text=True)
        self.expect("the workflow's own expression removes both forms",
              "Crate: rustls\nerror: 1 found", out.stdout.strip())

    def test_r2_s_scope_actions_are_watched_crates_deliberately_are_not(self):
        """R2's scope: actions are watched, crates deliberately are not"""
        self.expect("github-actions is watched", True, "package-ecosystem: github-actions" in dependabot)
        self.expect("cargo is not, because advisories.yml answers that question",
              False, "package-ecosystem: cargo" in dependabot)
        self.expect("a weekly schedule", True, "interval: weekly" in dependabot)
        # CI refuses a commit subject without both versions, so Dependabot's own
        # prefix has to carry a placeholder or every one of its PRs fails the hook.
        self.expect("its commit prefix carries both versions", True,
              bool(re.search(r'prefix: "app \d+\.\d+\.\d+ api \d+\.\d+"', dependabot)))

    def test_every_pinned_action_is_one_dependabot_can_actually_move(self):
        """every pinned action is one Dependabot can actually move"""
        pins = sorted(set(re.findall(r"uses: (\S+)", " ".join(
            p.read_text() for p in (ROOT / ".github/workflows").glob("*.yml")))))
        floating = [p for p in pins if not re.search(r"@v?\d", p)]
        # **No floating refs at all, since 2026-09-20.** This used to allow exactly one,
        # `dtolnay/rust-toolchain@stable`, on the grounds that a moving channel is not a
        # version and Dependabot leaves it alone. Both workflows have since dropped that
        # action: `rust-toolchain.toml` names the channel, the components and the
        # targets, and rustup installs all three when it activates the directory
        # override, so naming a version in a workflow was a second pin -- and Dependabot
        # misread the versioned form of it as Rust 1.120.0, which does not exist (#393).
        #
        # So the allowance is gone rather than widened. Any floating ref now is one
        # nobody is watching.
        self.expect("no action is pinned to something Dependabot cannot move", [], floating)


if __name__ == "__main__":
    unittest.main()

