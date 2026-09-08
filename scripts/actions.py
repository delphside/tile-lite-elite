#!/usr/bin/env python3
"""actions.py — every outstanding action and review, in one query, in workstream order.

Owner, 2026-08-19: *"We need to see: the workstream parent issue (if there is
one), child issues, child PRs, actions."* And, on whether the two are the same
thing: *"Are all actions on a PR? Then show the PR and action together."*

**They are not the same thing, and the distinction is the point.**

  - an **action** is an unchecked `- [ ]` in an *issue* body. It is the only
    surface we have that can carry state: an issue holds one bit, a comment is
    append-only, a pull request body freezes at merge. See #181.
  - a **review checklist** is the same syntax in a *pull request* body, and is
    not an action — it is the review itself, and it appears as the pull request
    rather than as a list of boxes.

So a pull request and the actions on its issue are shown together, under that
issue, which is what the request amounts to once the two are separated.

**Structure comes from GitHub, not from a convention we maintain.** Parent and
sub-issue links are real (`subIssues`, `parent`), so a workstream is read rather
than inferred. Dependencies are real too since 2026-08-28 — GitHub's own
`blocked by` links, which replaced `roadmap.sh`'s "mentioned by", a column that
read prose because nothing better existed when it was written.

A pull request is attached to its issue by **branch name** (`issue-<n>-…`),
which is the convention `status.sh` already relies on, and listed separately
when the name does not follow it — a branch that cannot be placed is worth
seeing rather than hiding.

Read-only and derived: nothing is stored, so nothing can drift.
"""
import json
import os
import re
import subprocess
import datetime as dt
import sys

BOLD, DIM, OFF = "\033[1m", "\033[2m", "\033[0m"

# **The default is Steve's view, and it prunes.** Owner, 2026-08-19: *"actions.sh
# should be there primarily to show me the workstreams, issues and PRs with
# actions for me. I can then look at them in GitHub."* So a workstream with
# nothing waiting on him does not appear at all — this is a pointer at GitHub,
# not a reader for it, and every line that is not his is a line in the way.
#
#   (no flag)   waiting on Steve: his actions, and pull requests labelled
#               a review request
#   --claude    the same for Claude's side
#   --all       everything, including what is finished and what is nobody's
MODE = sys.argv[1] if len(sys.argv) > 1 else ""
if MODE not in ("", "--claude", "--all"):
    print("usage: actions.py [--claude|--all]", file=sys.stderr)
    sys.exit(2)
WHO = "Claude" if MODE == "--claude" else "" if MODE == "--all" else "Steve"
NO_WORKSTREAM = "no workstream — needs triage"
POST_DEPLOYMENT = "Post-deployment"
# D4: the review is written "once the project's last release has been live and
# used, not on the day it ships — a week is usually enough for the interesting
# failures to surface". So nothing is said before then; a reminder that fires on
# day one is one you learn to ignore.
REVIEW_DUE_DAYS = 7
# The label the owner added 2026-09-04: "once deployed this change will be
# checked in the next release as a post-deployment check". It marks a review
# that *cannot* be written yet rather than one nobody has got to — #214's digest
# comparison needs a later release to compare against. Nagging about a thing
# nobody can do teaches people to ignore the nag, so it is shown as waiting
# instead (#310).
RELEASE_CHECK = "Release Check"

# D45: a Decision's state says who is holding it, and every transition
# alternates. Routing used to come from the `(Steve)` / `(Claude)` prefixes,
# which meant a tick decided ownership — #321 was answered in a comment with its
# `(Steve) choose` ticked, and left the owner's list for nobody's. A tick means
# a task is done; it should not say whose turn it is.
#
# One table, because these strings are matched literally and a mismatch is
# silent: `For agreement` against the real `Feedback Provided` cost an afternoon.
DECISION_HOLDER = {
    "Asked": "Steve",               # Claude raised it; the owner gives his view
    "Feedback Provided": "Claude",      # he has commented; Claude responds and documents it
    "Documented Ready for Sign-Off": "Steve",  # written down; he reads it and signs it off
    "Decided": "Claude",            # signed off; this is when applying falls due
    "Actioned": "Steve",            # applied; he reads the outcome and closes it
}
# The act each state calls for. At `Asked` and `Decided` the body's own actions
# usually say it with more detail, so these are the fallback there — used when
# the body has none left to show. Without that fallback a decision whose boxes
# are all ticked disappears from both lists while its state still says somebody
# is holding it, which is the tick problem in its last hiding place: #321 was
# ticked at `Asked` and would have gone back there invisible.
DECISION_TURN = {
    "Asked": "(Steve) choose between the options",
    "Feedback Provided": "(Claude) respond, and document the agreed decision in the body",
    "Documented Ready for Sign-Off": "(Steve) read the agreed decision, tick the box and move it to Decided",
    "Decided": "(Claude) signed off — apply it",
    "Actioned": "(Steve) applied — read the agreed decision and close it",
}
# The two states where the body's own `Open actions` are what is due. Everywhere
# else the state's act is the whole of it, and showing the body's actions is how
# "apply it" came to appear on Claude's list while #321 was still `Asked`.
DECISION_BODY_ACTIONS = {"Asked", "Decided"}
ALL = MODE == "--all"

QUERY = """
{ repository(owner: "%s", name: "%s") {
    issues(states: OPEN, first: 100) {
      nodes { number title body state
              issueType { name }
              labels(first: 20) { nodes { name } }
              issueFieldValues(first: 20) { nodes {
                ... on IssueFieldSingleSelectValue {
                  field { ... on IssueFieldSingleSelect { name } } value } } }
              parent { number }
              subIssues(first: 50) { nodes { number title state issueType { name } } } } }
    pullRequests(states: OPEN, first: 50) {
      nodes { number title headRefName isDraft
              reviewDecision
              reviewRequests(first: 10) {
                nodes { requestedReviewer { ... on User { login } } } }
              files(first: 30) { nodes { path additions deletions } } } } } }
"""


def field(node: dict, name: str) -> str:
    """One issue field's value on an issue, or "" when it is unset.

    **Single-select only.** `SINGLE_SELECT` is GitHub's own name for the data
    type, and the value comes back as a plain string.
    """
    for v in node.get("issueFieldValues", {}).get("nodes", []):
        if (v.get("field") or {}).get("name") == name:
            return v.get("value") or ""
    return ""


def workstream_order(owner: str) -> list[str]:
    """The `Workstream` field's values, in the order the field defines them.

    Alphabetical would be an accident: the order is deliberate — the centre
    first, then the subsystems carved out of it, then the workstreams that
    support the work rather than doing it. Reading it costs one query and keeps
    this file from holding a second copy of the list.
    """
    raw = gh("api", "graphql", "-f", "query=" + """
      { organization(login: "%s") { issueFields(first: 20) { nodes {
          ... on IssueFieldSingleSelect { name options { name } } } } } }
      """ % owner)
    try:
        nodes = json.loads(raw)["data"]["organization"]["issueFields"]["nodes"]
    except Exception:
        return []
    for f in nodes:
        if f.get("name") == "Workstream":
            return [o["name"] for o in f.get("options", [])]
    return []


def post_deployment_days(owner: str, repo: str, numbers: list[int]) -> dict[int, int]:
    """Days each project has sat at `Post-deployment`, keyed by issue number.

    **The clock is GitHub's, not ours.** A field *value* carries no timestamp,
    but the *issue* records every change: `IssueFieldChangedEvent` and
    `IssueFieldAddedEvent` are timeline items with `createdAt`, `previousValue`
    and `newValue`. So nothing has to be stored, and a project moved by hand is
    dated exactly like one moved by `deploy.sh` — which matters, because a
    `no-release` project is never touched by a deploy at all.

    **Matched on the value moved *to*, at the time it was set.** The events keep
    the option name as it was, and renaming an option does not rewrite them: the
    `Scope and design` option became `Scope` on 2026-08-31, so every earlier
    event still says the old name. Anything matching against the *current* option
    list would silently miss all of it.

    Queried only for the projects that are already at that phase — a handful —
    rather than widening the query that fetches every issue.
    """
    if not numbers:
        return {}
    parts = " ".join(
        f'i{n}: issue(number: {n}) {{ number timelineItems(last: 30, '
        f"itemTypes: [ISSUE_FIELD_CHANGED_EVENT, ISSUE_FIELD_ADDED_EVENT]) {{ nodes {{ "
        f"... on IssueFieldChangedEvent {{ createdAt newValue "
        f"issueField {{ ... on IssueFieldSingleSelect {{ name }} }} }} "
        f"... on IssueFieldAddedEvent {{ createdAt value "
        f"issueField {{ ... on IssueFieldSingleSelect {{ name }} }} }} }} }} }}"
        for n in numbers
    )
    query = f'{{ repository(owner: "{owner}", name: "{repo}") {{ {parts} }} }}'
    try:
        data = json.loads(gh("api", "graphql", "-f", f"query={query}"))
    except Exception:
        # A clock we cannot read is not a reminder we should invent.
        return {}
    today = dt.datetime.now(dt.timezone.utc)
    out: dict[int, int] = {}
    for node in (data.get("data", {}).get("repository") or {}).values():
        if not isinstance(node, dict):
            continue
        when = None
        for ev in node.get("timelineItems", {}).get("nodes", []):
            if (ev.get("issueField") or {}).get("name") != "Phase":
                continue
            if (ev.get("newValue") or ev.get("value")) == POST_DEPLOYMENT:
                when = ev.get("createdAt")
        if when:
            moved = dt.datetime.fromisoformat(when.replace("Z", "+00:00"))
            out[node["number"]] = (today - moved).days
    return out


def branches() -> set[int]:
    """Issue numbers with a branch of their own, local or on the remote.

    The same signal `status.sh` uses: a branch named `<n>-…` means somebody
    started. Without it "not started" and "in progress" look identical from the
    issue alone, and the difference is the whole point of the distinction.

    **Both spellings.** Branches were `issue-<n>-…` until 2026-09-05 and are
    `<n>-…` since; the `commit-msg` hook has always accepted either. This
    matched only the old one, so every branch cut after that date read as no
    branch at all.

    Anchored to the start of the branch name, after an optional `origin/`, so a
    number inside a slug cannot match — `release/0.7.3` and `main` match
    nothing, which is right: neither belongs to an issue.
    """
    out = subprocess.run(["git", "branch", "-a", "--format=%(refname:short)"],
                         capture_output=True, text=True).stdout
    return {int(m.group(1))
            for m in re.finditer(r"^(?:origin/)?(?:issue-)?(\d+)-", out, re.M)}


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True).stdout


def actions_in(body: str) -> list[str]:
    """Unchecked items under an `Open actions` heading, wrapped lines joined.

    **Only that section is read.** Owner, 2026-08-20, having left two tables in an
    issue body he wanted to delete: *"I left the tables because I wasn't sure if
    they were automated and I didn't want to break the tooling."* A tool that
    reads a whole body makes every edit a risk, because nothing tells you which
    part is load-bearing. Scoping it to one named heading makes the contract
    visible from inside the document, and matches `docs.yml`, which reads only
    the `## Review` section of a pull request body.

    So: everything outside `## Open actions` is prose, and free.

    An item ends at a blank line, at the next item, or at anything not indented.
    Without the blank-line rule this swallowed the paragraph after the list —
    which it did, visibly, the first time it ran.
    """
    out: list[str] = []
    open_item = False
    in_section = False
    fence = False
    for line in (body or "").split("\n"):
        # A fenced block is an example, not content. #181 documents the
        # convention by showing an `## Open actions` block, and without this the
        # tool read its own documentation as live actions — which it did.
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            in_section = bool(re.match(r"open actions", heading.group(2).strip(), re.I))
            open_item = False
            continue
        if not in_section:
            continue
        if re.match(r"^\s*- \[[ x]\]", line):
            if re.match(r"^\s*- \[ \]", line):
                out.append(re.sub(r"^\s*- \[ \]\s*", "", line))
                open_item = True
            else:
                open_item = False
        elif open_item and line.strip() and re.match(r"^\s+\S", line):
            out[-1] += " " + line.strip()
        else:
            open_item = False
    return out


# Whether CI has *failed* for what is on `main`, as a line to print.
#
# Delegated to `ci-status.sh` rather than asking GitHub here, so the release
# gate, `verify.sh` and this all read the same answer and cannot drift — which
# is that script's own reason for existing.
#
# Only a concluded failure is reported. A run still in progress is the normal
# state right after a push and would be noise on every reading; a run that does
# not exist yet is not evidence of anything.
#
# Raised by the day of 2026-09-04: CI was red on `main` for fourteen commits
# because the tool that checks it, `verify.sh`, was not run. This one is.
def ci_failed_on_main() -> str | None:
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        r = subprocess.run([os.path.join(here, "ci-status.sh"), "--run", "push:main"],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    if r.returncode == 0:
        return None
    text = (r.stdout or "") + (r.stderr or "")
    if "concluded" not in text:
        return None          # in progress, or no run yet
    for line in text.splitlines():
        if "concluded" in line:
            return line.strip()
    return None


# Days until the token `gh` runs on expires, and None if it does not expire or
# the header is missing.
#
# A countdown rather than a warning under a threshold (owner, 2026-09-04):
# there is no right number of days to start caring, and a figure that is always
# there needs no decision about when to appear. It is a check and never a gate —
# nothing here refuses anything.
#
# Raised by #309: the fine-grained token expires 2026-11-24 and nothing warns.
# GitHub emails 45 days ahead about 2FA and says nothing at all about this, so
# the first symptom would be a command failing in the middle of something else.
# The whole cost is one header on a call already being made.
def token_days_left() -> int | None:
    out = gh("api", "-i", "user", "--silent")
    for line in out.splitlines():
        if line.lower().startswith("github-authentication-token-expiration:"):
            when = line.split(":", 1)[1].strip()
            for fmt in ("%Y-%m-%d %H:%M:%S %Z", "%Y-%m-%d %H:%M:%S UTC"):
                try:
                    expiry = dt.datetime.strptime(when, fmt)
                except ValueError:
                    continue
                # UTC on both sides. The header is UTC and `date.today()` is
                # local, so between midnight BST and midnight UTC they are
                # different days and the countdown is out by one — which is
                # exactly when the test caught it, at 00:43 BST on 2026-09-05.
                return (expiry.date() - dt.datetime.now(dt.timezone.utc).date()).days
    return None


def main() -> int:
    repo = gh("repo", "view", "--json", "owner,name",
              "--jq", '"\\(.owner.login) \\(.name)"').split()
    if len(repo) != 2:
        print("actions.py: could not identify the repository", file=sys.stderr)
        return 1
    repo_owner = repo[0]
    raw = gh("api", "graphql", "-f", "query=" + QUERY % (repo[0], repo[1]))
    if not raw:
        print("actions.py: no answer from GitHub", file=sys.stderr)
        return 1
    data = json.loads(raw)["data"]["repository"]

    issues = {n["number"]: n for n in data["issues"]["nodes"]}
    prs = data["pullRequests"]["nodes"]

    pr_for: dict[int, list[dict]] = {}
    homeless: list[dict] = []
    for pr in prs:
        # Both spellings — see `branches()`. Matching only `issue-<n>-` sent
        # every pull request opened after 2026-09-05 to `homeless`, which is
        # printed under `--all` and nowhere else: a pull request awaiting the
        # owner's review was invisible in the view that exists to show him what
        # is waiting.
        m = re.match(r"(?:issue-)?(\d+)-", pr["headRefName"])
        (pr_for.setdefault(int(m.group(1)), []).append(pr) if m else homeless.append(pr))

    started = branches()

    def status(num: int, state: str) -> tuple[str, str]:
        """Where a project is: its phase if it has one, else derived progress.

        A **phase** is hand-set in the `Phase` issue field, because the
        interesting boundaries are judgements — "user testing is finished" is
        not visible to a script. It is a rare, deliberate act, which is when
        hand-set state is honest. Owner, 2026-08-19: *"the point is to identify
        a project phase as much as to identify decision gates."*

        **It was a `phase:` label until 2026-08-27.** The field carries the same
        five values from a fixed list, and is what the projects board columns
        read.

        Everything without a phase falls back to the three derived states, so an
        issue that is not a project still says whether anybody has started — and
        so does a project nobody has picked up, which is what an unset field
        means.
        """
        if state != "OPEN":
            return "completed", DIM
        if phase := field(issues.get(num, {}), "Phase"):
            return phase.lower(), ""
        if num in pr_for or num in started:
            return "in progress", ""
        return "not started", DIM

    # **A workstream is a field, not a parent** — since #232. It used to be an
    # issue that other issues were sub-issues of, which made the workstream list
    # a set of container issues existing only to be parents. What survives is
    # the *parent link*, which now means one thing: this requirement belongs to
    # that project.
    # Only a **project's** sub-issues are "drawn under their parent". The
    # workstream issues still exist until #232's step 5 and still have
    # sub-issues, and counting those would hide every issue in the listing —
    # which is exactly what happened the first time this was run.
    parents = [i for i in issues.values()
               if i["subIssues"]["nodes"]
               and (i.get("issueType") or {}).get("name") not in ("Workstream", "Index")]
    children = {c["number"] for p in parents for c in p["subIssues"]["nodes"]}
    def level(num: int) -> str:
        """Requirement, Project, Workstream or Index — GitHub's own issue type.

        **Read rather than derived, since 2026-08-26.** It used to be inferred
        from the sub-issue graph: *a parent that is itself somebody's sub-issue
        is a project; a parent with nobody above it is a workstream*. That was
        true and it failed for a workstream created before its first project —
        #204 registered as an untriaged requirement on the day it was made.

        An issue type says what a thing **is**, rather than leaving it to be
        worked out from what happens to point at it.

        **No fallback to the old inference.** An issue with no type reads as
        plain `issue`, which looks wrong in the output and is meant to — every
        one of the 194 was backfilled, so a blank means somebody raised one
        without choosing. Guessing would hide that, and guessing *by the old
        rule* would reproduce the bug it replaced.
        """
        return ((issues.get(num, {}).get("issueType") or {}).get("name")
                or "issue").lower()

    def kind_of(node: dict) -> str:
        """The level of a sub-issue node, which may be closed.

        `issues` holds **open** issues only, so a closed child is not in it and
        `level()` would call it a plain `issue`. The sub-issue node carries its
        own type, so a delivered project still reads as a project.
        """
        return ((node.get("issueType") or {}).get("name") or "issue").lower()

    def reviewers(pr: dict) -> set[str]:
        return {r["requestedReviewer"]["login"]
                for r in pr["reviewRequests"]["nodes"]
                if r.get("requestedReviewer", {}).get("login")}

    def turn(pr: dict) -> str:
        """Whose turn it is, read from GitHub rather than from a label.

        **The label was a second store for what GitHub already knew.** It
        existed because `gh` ran under the owner's token, so every pull request
        was authored by him and GitHub refused self-approval — the native state
        was unreachable, not unwanted. A second account (#171) made it
        reachable, and #219 proved it: `reviewDecision: APPROVED`, on a pull
        request authored by `SteveStyle-typed-by-Claude`.

        So `approved`, `provisionally-approved` and `awaiting-review` are gone,
        along with the comment parser that set them. What replaces
        `awaiting-review` is a **review request**, which GitHub surfaces in the
        reviewer's own queue — something the label never did.

        `provisionally-approved` has no native equivalent and is not replaced.
        Owner, 2026-08-23: *"in the absence of provisional approval, I can use
        [request] changes and approve when you say they are done."* That costs
        a lap and buys a look at the change before it merges, which `/prov` did
        not give.
        """
        if pr["isDraft"]:
            return "draft"
        decision = pr.get("reviewDecision")
        if decision == "APPROVED":
            return "approved — mine to merge"
        if decision == "CHANGES_REQUESTED":
            return "changes requested — mine to make"
        if reviewers(pr):
            return "your turn"
        return "in hand"

    # Projects left open at Post-deployment for their review (#263), and how
    # long they have been waiting. Computed once, for the few that qualify.
    #
    # **Attributed to Claude**, because D4 says the review is written by Claude
    # and reviewed by Steve — so until a draft exists it is not Steve's turn.
    # The escalation past that is `verify.sh`'s, which fails once a *later*
    # release has shipped: two levels, in two tools, rather than one nag that
    # has to decide on its own how cross to be.
    awaiting_review = post_deployment_days(
        repo[0], repo[1],
        [n for n, i in issues.items()
         if (i.get("issueType") or {}).get("name") == "Project"
         and field(i, "Phase") == POST_DEPLOYMENT],
    )

    def mine(num: int) -> tuple[list[str], list[dict]]:
        """The actions and pull requests this run is about — the filter, in one place."""
        items = [a for a in actions_in(issues.get(num, {}).get("body", ""))
                 if ALL or a.startswith(f"({WHO})")]
        labels = {l["name"] for l in
                  (issues.get(num, {}).get("labels") or {}).get("nodes", [])}
        node = issues.get(num, {})
        # A decision that is applied but not yet closed is waiting to be *read*.
        # D44: `Actioned` means the work is done, closed means the outcome has
        # been seen, and those are different moments — #323 was agreed, applied
        # and closed inside one exchange, so its outcome never reached anybody.
        # Nothing enforces the closing; this is what makes it visible.
        if (node.get("issueType") or {}).get("name") == "Decision":
            dstate = field(node, "Decision State")
            holder = DECISION_HOLDER.get(dstate)
            if holder is None:
                # An unset or unrecognised state: fall back to the body, rather
                # than silently showing nothing. `check-transitions.sh` reports
                # the missing state separately.
                pass
            elif not ALL and holder != WHO:
                items = []
            else:
                turn_item = DECISION_TURN.get(dstate, "")
                mine_turn = turn_item and (ALL or turn_item.startswith(f"({WHO})"))
                if dstate not in DECISION_BODY_ACTIONS:
                    # The state's own act is the whole of what is due here.
                    items = [turn_item] if mine_turn else []
                elif not items and mine_turn:
                    # The body has nothing left to show, but the state still
                    # says this side is holding it. Say so rather than vanish.
                    items = [turn_item]
        days = awaiting_review.get(num, 0)
        if days >= REVIEW_DUE_DAYS and RELEASE_CHECK in labels:
            # Visible, and never anybody's action: the difference between "you
            # have not done this" and "this cannot be done yet".
            if ALL:
                items.insert(0, f"(release) waits for the next release — "
                                f"{days} days at Post-deployment")
        elif days >= REVIEW_DUE_DAYS:
            due = (f"(Claude) post-deployment review is due — {days} days at "
                   f"Post-deployment. docs/templates/post-deployment-review.md")
            if ALL or due.startswith(f"({WHO})"):
                items.insert(0, due)
        wanted = pr_for.get(num, [])
        if not ALL:
            # Whose turn, from GitHub's own answer. Steve's if a review is
            # requested from him and he has not given one; Claude's once it is
            # approved, changes are requested, or nobody is waiting on anybody.
            if WHO == "Steve":
                wanted = [pr for pr in wanted if turn(pr) == "your turn"]
            else:
                wanted = [pr for pr in wanted
                          if turn(pr) in ("approved — mine to merge",
                                          "changes requested — mine to make",
                                          "in hand")]
        return items, wanted

    def show_prs_and_actions(num: int, indent: str = "  ") -> None:
        items, wanted = mine(num)
        # Actions before pull requests: the thing to *do* reads first, and a
        # pull request is a thing to look at. Owner's preference, 2026-08-19.
        for item in items:
            text = re.sub(r"^\((?:Steve|Claude)\)\s*", "", item)
            who = "Steve " if item.startswith("(Steve)") else "Claude" if item.startswith("(Claude)") else "      "
            print(f"{indent}   - {who if ALL else '     '} {text}")
        for pr in wanted:
            doc = sorted(pr["files"]["nodes"], key=lambda f: -(f["additions"] + f["deletions"]))
            path = doc[0]["path"] if doc else ""
            extra = f"  +{len(doc) - 1} more" if len(doc) > 1 else ""
            print(f"{indent}   PR #{pr['number']:<5} {pr['title']}  {DIM}[{turn(pr)}]{OFF}")
            if path:
                print(f"{indent}            {DIM}{path}{extra}{OFF}")
        # Every other open pull request on this issue, one dim line each.
        # Owner, 2026-08-21: *"can actions.py also show the project and the PR
        # number?"* — the filter above decides what is **actionable**, and that
        # is a different question from what is **relevant**. An issue you are
        # already reading should say which pull request belongs to it, even
        # when the turn is not yours: otherwise the number has to be looked up
        # somewhere else every time.
        rest = [pr for pr in pr_for.get(num, []) if pr not in wanted]
        for pr in rest:
            print(f"{indent}   {DIM}PR #{pr['number']:<5} {pr['title']}  [{turn(pr)}]{OFF}")

    def has_something(num: int, state: str) -> bool:
        if ALL:
            return True
        items, wanted = mine(num)
        return state == "OPEN" and bool(items or wanted)

    def show_issue(num: int, title: str, state: str = "OPEN", indent: str = "  ",
                   kind: str = "issue") -> None:
        label, shade = status(num, state)
        print(f"{indent}{shade}{kind} #{num:<5} {title}  [{label}]{OFF if shade else ''}")
        # A completed issue is one line. Its pull request is merged and its
        # actions are done, so printing them is length without information —
        # which is what makes a growing workstream unreadable.
        if label != "completed":
            show_prs_and_actions(num, indent)

    whose = "everything" if ALL else f"waiting on {WHO}"
    print(f"{BOLD}ACTIONS{OFF}  {DIM}{whose} — open it in GitHub to act on it{OFF}")

    # Grouped by the **Workstream field**, in the order the field defines. An
    # issue with no workstream is the triage queue, and is drawn last under its
    # own heading rather than being left out — an untriaged issue that nothing
    # shows is the failure this whole listing exists to prevent.
    order = workstream_order(repo_owner)
    grouped: dict[str, list[dict]] = {}
    for i in issues.values():
        if (i.get("issueType") or {}).get("name") in ("Workstream", "Index"):
            continue  # a container, until #232's step 5 removes them
        if i["number"] in children:
            continue  # drawn under its project, below
        grouped.setdefault(field(i, "Workstream") or NO_WORKSTREAM, []).append(i)

    shown = False
    for ws in [w for w in order if w in grouped] + \
              [w for w in sorted(grouped) if w not in order]:
        members = sorted(grouped[ws], key=lambda i: i["number"])
        drawn = [i for i in members
                 if ALL or has_something(i["number"], i["state"])
                 or any(has_something(g["number"], g["state"])
                        for g in i["subIssues"]["nodes"])]
        if not drawn:
            continue
        shown = True
        print(f"\n{BOLD}{ws}{OFF}")
        for c in drawn:
            # A project with sub-issues gets a heading and its requirements are
            # indented beneath it. That is the parent link's only remaining
            # meaning since #232: this requirement belongs to that project.
            grand = c["subIssues"]["nodes"]
            if grand:
                print(f"  {BOLD}{kind_of(c)} #{c['number']}  {c['title']}{OFF}")
                show_prs_and_actions(c["number"], indent="  ")
                for g in grand:
                    if ALL or has_something(g["number"], g["state"]):
                        # Its type too: a requirement folded into a project is
                        # still a requirement, and `issue` says less than it did
                        # before the levels existed.
                        show_issue(g["number"], g["title"], g["state"],
                                   indent="    ", kind=kind_of(g))
            else:
                show_issue(c["number"], c["title"], c["state"], kind=kind_of(c))
    loose = []

    if not (shown or loose or homeless):
        print(f"\n  {DIM}nothing waiting{OFF}")

    if homeless and ALL:
        print(f"\n{BOLD}pull requests with no issue in the branch name{OFF}")
        for pr in homeless:
            print(f"  PR #{pr['number']:<5} {pr['title']}  {DIM}[{turn(pr)}] {pr['headRefName']}{OFF}")

    broken = ci_failed_on_main()
    if broken:
        print(f"\n  {BOLD}{broken}{OFF}")
        print(f"  {BOLD}Nothing after the failing step ran — no clippy, no tests, no wasm.{OFF}")

    days = token_days_left()
    if days is not None:
        # The wording carries the urgency; the line is always present either way.
        if days <= 7:
            note = f"{BOLD}token expires in {days} days — regenerate it now (#309){OFF}"
        elif days <= 30:
            note = f"token expires in {days} days (#309)"
        else:
            note = f"{DIM}token expires in {days} days{OFF}"
        print(f"\n  {note}")

    print(f"\n{DIM}Read-only, derived at run time — the issue body is the record.{OFF}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
