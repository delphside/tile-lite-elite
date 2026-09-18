#!/usr/bin/env bash
set -euo pipefail

# advisories.test.sh — the dependency advisory check, #297.
#
# Everything here is a way the check could go quietly wrong. A security check
# that fails loudly gets fixed; one that passes when it should not is worse
# than none, because it is also reassuring.
#
#   pipefail        without it the audit's exit status is `tee`'s, which is
#                   always zero, and every run is green forever
#   reasons         audit.toml's own header: an entry with no reason is
#                   indistinguishable from something nobody looked at
#   the printer     what a green run suppressed (#339) — untested because it
#                   lives inside the workflow YAML, so extract and run it
#   R2's scope      github-actions watched, cargo deliberately not
#
# No network: the repository's own files only.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE/.."

python3 - <<'PY'
import pathlib, re, subprocess, sys, textwrap

failures = 0

def check(what, want, got):
    global failures
    if got == want:
        print(f"  ok   {what}")
    else:
        print(f"  FAIL {what}\n       want {want!r}\n       got  {got!r}")
        failures += 1

wf = pathlib.Path(".github/workflows/advisories.yml").read_text()
audit = pathlib.Path(".cargo/audit.toml").read_text()
dependabot = pathlib.Path(".github/dependabot.yml").read_text()

print("the audit's exit status is the audit's, not tee's")
# `cargo audit ... | tee` without pipefail reports tee's status, which is
# always zero. The check would pass for ever and nobody would see it happen.
run = re.search(r"name: Audit\b.*?run: \|\n(.*?)\n      - name:", wf, re.S)
check("the Audit step exists", True, run is not None)
body = run.group(1) if run else ""
check("pipefail is set before the pipe", True, "set -o pipefail" in body)
check("the audit is piped through tee", True, "| tee" in body)
check("it denies warnings, since severity does not track reachability",
      True, "--deny warnings" in body)

print()
print("the report is opened on failure, and a failing step cannot skip it")
# `if: always()` matters: without it the failed audit ends the job and the
# report never reaches anybody, which is the whole point of the workflow.
report = re.search(r"name: Open or update the report\n\s*if: ([^\n]+)", wf)
check("the report step is guarded by always()", True,
      report is not None and "always()" in report.group(1))
check("and only fires when the audit failed", True,
      report is not None and "outcome == 'failure'" in report.group(1))
check("the issue it raises carries a type, so rules do not skip it (#361)",
      True, "--type Requirement" in wf)

print()
print("every quieted advisory says why — audit.toml's own rule")
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
check("the list is not empty", True, len(ids) > 0)
check("no duplicated ids", len(ids), len(set(ids)))
check("every entry has a reason", [], missing)

print()
print("the printer that says what a green run suppressed (#339)")
# It lives inside the workflow YAML, where nothing can reach it. Extract and
# run it, so a change to it is covered like any other code.
block = re.search(r"python3 - <<'EOF'\n(.*?)\n\s*EOF", wf, re.S)
check("the printer is found in the workflow", True, block is not None)
if block:
    src = textwrap.dedent(block.group(1))
    out = subprocess.run([sys.executable, "-c", src], capture_output=True, text=True)
    check("it runs", 0, out.returncode)
    check("it reports every entry", True, f"{len(ids)} advisories" in out.stdout)
    check("and flags nothing as reasonless", False, "NO REASON RECORDED" in out.stdout)

print()
print("the report is readable, not raw terminal output")
# cargo audit writes ANSI to the pipe and tee keeps it. #384 arrived with
# `^[[0m^[[1m^[[31m` around every field -- legible only to somebody willing to
# read past it, which is what #297 R3 says a report must not require.
check("the colour is stripped before the body is written",
      True, "sed -r" in wf and "/tmp/audit.txt" in wf and "[0-9;]*[a-zA-Z]" in wf)
# GitHub rewrites a real ESC to the literal "^[" on the way in, so #384 could
# not be cleaned by matching \x1b alone. Both forms are handled.
check("and the literal ^[ form too", True, r"\^\[" in wf)
check("and the raw file is not pasted in", False, "cat /tmp/audit.txt" in wf)
# Run the workflow's OWN line, not a hand-written copy of it: a test that
# writes its own expression proves only that the test author can write sed.
line = [l for l in wf.splitlines() if l.strip().startswith("sed -r")][0].strip()
sample = "\x1b[0m\x1b[1m\x1b[31mCrate:\x1b[0m rustls\n^[[31merror:^[[0m 1 found\n"
out = subprocess.run(["bash", "-c", line.replace("/tmp/audit.txt", "-")],
                     input=sample, capture_output=True, text=True)
check("the workflow's own expression removes both forms",
      "Crate: rustls\nerror: 1 found", out.stdout.strip())

print()
print("R2's scope: actions are watched, crates deliberately are not")
check("github-actions is watched", True, "package-ecosystem: github-actions" in dependabot)
check("cargo is not, because advisories.yml answers that question",
      False, "package-ecosystem: cargo" in dependabot)
check("a weekly schedule", True, "interval: weekly" in dependabot)
# CI refuses a commit subject without both versions, so Dependabot's own
# prefix has to carry a placeholder or every one of its PRs fails the hook.
check("its commit prefix carries both versions", True,
      bool(re.search(r'prefix: "app \d+\.\d+\.\d+ api \d+\.\d+"', dependabot)))

print()
print("every pinned action is one Dependabot can actually move")
pins = sorted(set(re.findall(r"uses: (\S+)", " ".join(
    p.read_text() for p in pathlib.Path(".github/workflows").glob("*.yml")))))
floating = [p for p in pins if not re.search(r"@v?\d", p)]
# `@stable` is a moving toolchain channel, not a version: nothing to bump, and
# Dependabot leaves it alone. Any OTHER floating ref is one nobody is watching.
check("the only unversioned pin is the toolchain channel",
      ["dtolnay/rust-toolchain@stable"], floating)

print()
if failures:
    print(f"{failures} failure(s)")
    sys.exit(1)
print("all advisory cases hold")
PY
