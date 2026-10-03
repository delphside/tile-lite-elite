#!/usr/bin/env python3
"""Validate a stream of log lines against the schema `docs/4.7` declares.

**Reads; never drives.** Two callers feed it, and the difference is the source
of the lines rather than anything this script does:

  cargo test with TILE_LITE_ELITE_LOG_CAPTURE=... , then this over the file
      CI. The regression suite already exercises registration, login,
      invitations and the whole password-reset family — including the rare
      branches a week of production would not show.

  journalctl CONTAINER_TAG=tle-server -o cat | this --source production
      the nightly check on the host. It creates nothing and touches nothing.

Owner, 2026-08-21: *"our normal regression tests will generate all of the log
messages anyway, so running the check as part of CI should cover it… the
production check should just check the production logs, and write its own
exception log."*

What it asserts, in order of how much each is worth:

  1. no email address reaches the log, in any field of any event
  2. a declared event carries exactly the fields `docs/4.7` declares — no more,
     which is the leak this exists to catch, and no fewer
  3. every object in the schema sets `additionalProperties: false`. A schema
     that has quietly stopped guarding passes everything, so the property is
     checked rather than trusted — JSON Schema is permissive by default and one
     omission would be a silent hole
  4. no `debugOnly` event appears in a production stream. Only
     `docker-compose.preview.yml` sets the variable that permits it, so its
     presence on production means somebody set it there — which is a stronger
     signal than the build-profile guard it replaced, because a build profile
     can slip and a compose file is reviewed

An event the schema does not mention is **not** an error: the schema deliberately
covers the events carrying player identifiers, and `docs/4.7` says so. Rule 1
still applies to it, which is what keeps that decision safe.
"""

import argparse
import json
import pathlib
import re
import sys

def _doc() -> pathlib.Path:
    """Where `4.7-log-events.md` is, in both places this runs.

    In a checkout it is `../docs/4.7-log-events.md`. **On the production host
    there is no checkout** — `deploy.sh` ships images, not source — so the
    delivery copies this script, the document and the nightly wrapper into
    `/opt/tile-lite-elite/` together, side by side. They are one artefact in
    three files: the validator is useless without the schema, and a logging
    change that re-copies one without the other leaves the host validating
    against last month's document.
    """
    here = pathlib.Path(__file__).resolve().parent
    for candidate in (here.parent / "docs" / "4.7-log-events.md",
                      here / "4.7-log-events.md"):
        if candidate.exists():
            return candidate
    return here.parent / "docs" / "4.7-log-events.md"


DOC = _doc()
ENVELOPE = {"timestamp", "level", "message", "target"}
# Deliberately loose. A false positive costs somebody ten seconds; a missed
# address is the thing this whole part of the project exists to prevent.
ADDRESS = re.compile(r"[^\s@\"]+@[^\s@\"]+\.[a-z]{2,}", re.I)


def schema() -> dict:
    text = DOC.read_text(encoding="utf-8")
    block = re.search(r"<!-- log-schema -->\s*```json\n(.*?)\n```", text, re.S)
    if not block:
        sys.exit(f"{DOC}: no block marked `log-schema` — see 'The schema' there")
    return json.loads(block.group(1))


def strings(value):
    """Every string anywhere in a value, however nested."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("source_file", nargs="?", default="-",
                    help="a file of JSON log lines, or - for stdin")
    ap.add_argument("--source", choices=("ci", "production"), default="ci")
    args = ap.parse_args()

    sch = schema()
    events = sch["events"]
    problems: list[str] = []

    # 3 — the meta-check, before reading a single line. A schema that has stopped
    # guarding makes everything below meaningless, so it fails first and loudly.
    for name, spec in events.items():
        if spec.get("additionalProperties") is not False:
            problems.append(f"schema: {name!r} does not set additionalProperties: false")

    stream = sys.stdin if args.source_file == "-" else open(args.source_file, encoding="utf-8")
    seen = 0
    for number, line in enumerate(stream, 1):
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            # Not every line on a host's journal is ours — container start-up
            # banners, a panic backtrace. Only complain when it looks like it
            # was meant to be one of ours.
            if line.startswith("{"):
                problems.append(f"line {number}: not valid JSON — {line[:70]}")
            continue
        seen += 1
        message = event.get("message")
        spec = events.get(message)
        debug_only = bool(spec and spec.get("debugOnly"))

        # 4
        if debug_only and args.source == "production":
            problems.append(
                f"line {number}: {message!r} may not appear on production — it "
                "carries a whole email, and something has set "
                "TILE_LITE_ELITE_LOG_EMAIL_BODIES there")

        # 1 — skipped only for the one event whose whole purpose is to carry a
        # message body, and only where a debug build is expected.
        if not (debug_only and args.source == "ci"):
            for text in strings(event):
                found = ADDRESS.search(text)
                if found:
                    problems.append(
                        f"line {number}: {message!r} carries what looks like an "
                        f"address: {found.group(0)!r}")
                    break

        # 2
        if spec is not None:
            declared = set(spec.get("properties", {}))
            carried = set(event) - ENVELOPE
            for extra in sorted(carried - declared):
                problems.append(
                    f"line {number}: {message!r} carries {extra!r}, which docs/4.7 "
                    "does not declare")
            for missing in sorted(declared - carried):
                problems.append(
                    f"line {number}: {message!r} is missing {missing!r}, which "
                    "docs/4.7 declares")

    if stream is not sys.stdin:
        stream.close()

    print(f"log hygiene: {seen} events, {len(events)} declared, source {args.source}")
    for problem in problems:
        print(f"  EXCEPTION  {problem}")
    if problems:
        print(f"\n{len(problems)} exception(s).")
        return 1
    print("  every line clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
