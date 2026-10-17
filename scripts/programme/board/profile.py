"""The one place the tooling asks for a fact about an application or the programme (#485 stage 2).

The tooling holds no application's facts of its own. It reads three files and
stops, naming the file and the key, when one is missing; **it never falls back
to a built-in value**, because a default that happens to be one application's
would be believed in another's repository.

- **The programme file**, `config/programme.toml`: what every application
  shares (the organisation, the board, the accounts, the programme repository
  and its registers). Read from the *pinned* submodule,
  `<app root>/programme/config/programme.toml`, so it moves only when the pin
  does. `PROGRAMME_CONFIG` replaces the path (tests, CI).
- **The programme profile**, `applications/<app>/3.n.6-profile.md`: what the
  programme's processes need to know about this application, in fixed tables
  (identity, versioning, environments, routes, target architecture, records).
  Read from the *live* checkout (`records.live()`), because it is a record.
- **The technical profile**, `programme.toml` at the application's root: how
  versions are read, what ships, the commands. In the application's repository,
  with the code it describes. `PROGRAMME_PROFILE` replaces the path.

The application's root is the working tree git says we are in: the
superproject's when run inside a submodule, else this repository's top level.
That needs no git remote, so a test fixture is a directory and `git init`.

Shell scripts ask `board-profile.py get <key>`; this module is what it calls.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any

ENV_PROFILE = "PROGRAMME_PROFILE"
ENV_CONFIG = "PROGRAMME_CONFIG"

TECHNICAL_FILE = "programme.toml"

# Where the programme file is inside the pinned submodule. The submodule's own
# path is a fact the programme file holds, but the file cannot be found without
# it, so the first lookup uses this and nothing else does.
PINNED_PROGRAMME_FILE = Path("programme") / "config" / "programme.toml"

# The programme file's top-level sections. `get` sends a key to the programme
# file when it starts with one of these, to the programme profile when it
# starts with `profile`, and to the technical profile otherwise.
PROGRAMME_SECTIONS = ("organisation", "board", "accounts", "programme", "records",
                      "programme_documents")
PROFILE_PREFIX = "profile"


# **The exit status of a profile error: 70.** The commands that gate on this
# module answer in their exit status (`board-shipping.py`: 0 reaches the image,
# 1 does not, 2 usage; `board-documents.py` likewise), and a caller that reads
# any non-zero status as "no" would let an unreadable profile pass a gate. 70
# (sysexits' EX_SOFTWARE) is used by no answer, so a caller can tell "the
# profile is broken" from "the answer is no", and must refuse or stop on it.
EXIT_PROFILE_ERROR = 70


class ProfileError(SystemExit):
    """A profile, a key or a table is missing or malformed. Says which file and
    which key on stderr, when it is raised, and exits `EXIT_PROFILE_ERROR`."""

    def __init__(self, message: str):
        super().__init__(EXIT_PROFILE_ERROR)
        self.message = message
        print(f"profile: {message}", file=sys.stderr)


# --------------------------------------------------------------------------
# where the application is
# --------------------------------------------------------------------------

def _git(cwd: Path, *args: str) -> str:
    try:
        out = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True,
                             text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def app_root(start: Path | None = None) -> Path:
    """The application's root: the superproject's working tree when `start` is
    inside a submodule, else the top level of the working tree it is in."""
    here = Path(start) if start else Path.cwd()
    superproject = _git(here, "rev-parse", "--show-superproject-working-tree")
    if superproject:
        return Path(superproject)
    top = _git(here, "rev-parse", "--show-toplevel")
    if top:
        return Path(top)
    raise ProfileError(f"{here} is not inside a git working tree, so the application's "
                       f"root cannot be found")


def technical_path(root: Path | None = None) -> Path:
    given = os.environ.get(ENV_PROFILE)
    return Path(given) if given else (root or app_root()) / TECHNICAL_FILE


def programme_path(root: Path | None = None) -> Path:
    given = os.environ.get(ENV_CONFIG)
    return Path(given) if given else (root or app_root()) / PINNED_PROGRAMME_FILE


# --------------------------------------------------------------------------
# reading a TOML file
# --------------------------------------------------------------------------

_cache: dict[tuple[str, int, int], dict] = {}


def _toml(path: Path, what: str, hint: str) -> dict:
    try:
        stat = path.stat()
    except OSError:
        raise ProfileError(f"{what} not found at {path}: {hint}") from None
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    if key not in _cache:
        try:
            _cache[key] = tomllib.loads(path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise ProfileError(f"{what} at {path} cannot be read: {exc}") from None
    return _cache[key]


class Section:
    """A parsed file, asked by dotted key, naming the file when a key is missing."""

    def __init__(self, data: dict, source: str, prefix: str = ""):
        self.data = data
        self.source = source
        self.prefix = prefix  # what the caller's key starts with, for messages

    def get(self, dotted: str) -> Any:
        node: Any = self.data
        walked = []
        for part in dotted.split("."):
            walked.append(part)
            if not isinstance(node, dict) or part not in node:
                raise ProfileError(f"{self.source} has no key `{self.prefix}{'.'.join(walked)}` "
                                   f"(asked for `{self.prefix}{dotted}`)")
            node = node[part]
        return node

    def string(self, dotted: str) -> str:
        value = self.get(dotted)
        if not isinstance(value, str) or not value:
            raise ProfileError(f"{self.source}: `{dotted}` must be a non-empty string")
        return value

    def strings(self, dotted: str) -> list[str]:
        value = self.get(dotted)
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            raise ProfileError(f"{self.source}: `{dotted}` must be a list of strings")
        return value

    def tables(self, dotted: str) -> list[dict]:
        value = self.get(dotted)
        if not isinstance(value, list) or not all(isinstance(v, dict) for v in value):
            raise ProfileError(f"{self.source}: `{dotted}` must be a list of tables")
        return value


def technical(root: Path | None = None) -> Section:
    """The technical profile, `programme.toml` at the application's root."""
    path = technical_path(root)
    return Section(_toml(path, "the technical profile",
                         f"it is `{TECHNICAL_FILE}` at the application's root; set {ENV_PROFILE} "
                         f"to another path"),
                   f"the technical profile {path}")


def programme_file(root: Path | None = None) -> Section:
    """The programme file, from the pinned submodule."""
    path = programme_path(root)
    return Section(_toml(path, "the programme file",
                         f"it is `{PINNED_PROGRAMME_FILE}` in the pinned programme submodule "
                         f"(initialise it: git submodule update --init), or set {ENV_CONFIG}"),
                   f"the programme file {path}")


# --------------------------------------------------------------------------
# the programme profile: a record, in fixed tables
# --------------------------------------------------------------------------

def _clean(cell: str) -> str:
    return cell.strip().strip("`").strip()


def _tables(text: str) -> dict[str, list[list[str]]]:
    """Each `##` heading's first table, as rows of cells, header and rule dropped."""
    found: dict[str, list[list[str]]] = {}
    closed: set[str] = set()
    heading = None
    for line in text.splitlines():
        if line.startswith("## "):
            heading = line[3:].strip()
        elif heading is None:
            continue
        elif line.lstrip().startswith("|"):
            if heading not in closed:
                found.setdefault(heading, []).append(
                    [c.strip() for c in line.strip().strip("|").split("|")])
        elif heading in found:
            closed.add(heading)
    return {h: [r for r in rows[1:] if not all(re.fullmatch(r":?-+:?", c) for c in r)]
            for h, rows in found.items()}


def _snake(text: str) -> str:
    return re.sub(r"\W+", "_", text.strip().lower()).strip("_")


def parse_profile(text: str, source: str) -> dict:
    """The programme profile's tables as data. Raises, naming the table, when
    one is missing or a row the tooling needs is absent."""
    tables = _tables(text)

    def table(heading: str) -> list[list[str]]:
        if heading not in tables:
            raise ProfileError(f"{source} has no `## {heading}` table")
        return tables[heading]

    def fields(heading: str, wanted: tuple[str, ...]) -> dict[str, str]:
        got = {_snake(r[0]): _clean(r[1]) for r in table(heading) if len(r) >= 2}
        for name in wanted:
            if not got.get(name):
                raise ProfileError(f"{source}: the `{heading}` table has no `{name.replace('_', ' ')}` row")
        return got

    out: dict[str, Any] = {
        "identity": fields("Identity", ("name", "code", "number", "repository",
                                        "board_view", "document_range")),
        "versioning": fields("Versioning", ("scheme", "commit_stamp")),
    }
    envs = []
    for row in table("Environments"):
        if len(row) < 3:
            raise ProfileError(f"{source}: a row of the `Environments` table has fewer than 3 cells")
        url = row[2].strip()
        envs.append({"name": _clean(row[0]), "purpose": row[1].strip(),
                     # a URL in backticks is fixed; anything else says it is not
                     "url": _clean(url) if url.startswith("`") else ""})
    if not envs:
        raise ProfileError(f"{source}: the `Environments` table has no rows")
    out["environments"] = envs
    out["routes"] = {_clean(r[0]): r[1].strip() for r in table("Routes") if len(r) >= 2}
    link = re.search(r"\]\(([^)]+)\)", text.split("## Target architecture", 1)[-1]
                     if "## Target architecture" in text else "")
    if not link:
        raise ProfileError(f"{source}: `## Target architecture` has no link")
    out["target_architecture"] = link.group(1)
    records: dict[str, str] = {}
    for row in table("Records"):
        match = re.match(r"3\.(\d+)\.(\d+)\b", row[0]) if len(row) >= 2 else None
        if match:
            records[match.group(2)] = _clean(row[1])
    if not records:
        raise ProfileError(f"{source}: the `Records` table has no `3.n.x` rows")
    out["records"] = records
    return out


def application_folder(root: Path | None = None) -> str:
    """This application's folder in the programme repository, from the technical profile."""
    return technical(root).string("application")


def profile_path(root: Path | None = None) -> Path:
    """The programme profile in the live checkout: `applications/<app>/3.n.6-profile.md`."""
    from . import records
    folder = records.live(root) / "applications" / application_folder(root)
    found = sorted(folder.glob("3.*.6-*.md")) if folder.is_dir() else []
    if len(found) != 1:
        raise ProfileError(
            f"the programme profile is not at {folder}/3.n.6-*.md "
            f"({'none' if not found else 'several'} found): the application's record "
            f"in the live programme checkout needs one, from docs/templates/application-profile.md")
    return found[0]


_parsed: dict[tuple[str, int, int], dict] = {}


def application_profile(root: Path | None = None) -> dict:
    """The programme profile, parsed."""
    path = profile_path(root)
    stat = path.stat()
    key = (str(path), stat.st_mtime_ns, stat.st_size)
    if key not in _parsed:
        _parsed[key] = parse_profile(path.read_text(encoding="utf-8"),
                                     f"the programme profile {path}")
    return _parsed[key]


# --------------------------------------------------------------------------
# convenient, named questions
# --------------------------------------------------------------------------

def repository(root: Path | None = None) -> tuple[str, str]:
    """(owner, name) of this application's repository, from its programme profile."""
    nwo = application_profile(root)["identity"]["repository"]
    owner, _, name = nwo.partition("/")
    if not owner or not name:
        raise ProfileError(f"the programme profile's repository `{nwo}` is not `owner/name`")
    return owner, name


def organisation(root: Path | None = None) -> str:
    return programme_file(root).string("organisation.login")


def project_id(root: Path | None = None) -> str:
    return programme_file(root).string("board.project_id")


def owner_name(root: Path | None = None) -> str:
    """How the hook messages name the owner."""
    return programme_file(root).string("accounts.owner_name")


def programme_documents(root: Path | None = None) -> tuple[list[str], list[str]]:
    """(exact paths, prefixes) of the programme's documents an application holds:
    the programme file's list and the pinned submodule with everything in it,
    then the application's own from its technical profile."""
    config, spec = programme_file(root), technical(root)
    submodule = config.string("programme.submodule")
    exact = config.strings("programme_documents.exact") + [submodule] \
        + spec.strings("documents.programme_exact")
    prefixes = [submodule + "/"] + spec.strings("documents.programme_prefixes")
    return exact, prefixes


def tools_registers(root: Path | None = None) -> list[str]:
    """The registers a new script must be named in, as paths from the application's
    root: its own (technical profile), then the programme's inside the submodule."""
    config, spec = programme_file(root), technical(root)
    return spec.strings("documents.tools_registers") + [
        f"{config.string('programme.submodule')}/{config.string('programme_documents.tools_register')}"]


def current_version(which: str, root: Path | None = None) -> str | None:
    """The app or api version as the tree holds it now, or None when the file
    cannot be read or holds none. A key missing from the profile is an error."""
    root = root or app_root()
    spec = technical(root).get(f"versions.{which}")
    source = technical(root).source
    if not isinstance(spec, dict) or not isinstance(spec.get("file"), str):
        raise ProfileError(f"{source}: `versions.{which}` must be a table with a `file`")
    try:
        text = (root / spec["file"]).read_text(encoding="utf-8")
    except OSError:
        return None
    if "command" in spec:
        try:
            run = subprocess.run([str(root / spec["command"])], input=text, capture_output=True,
                                 text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return None
        return run.stdout.strip() or None if run.returncode == 0 else None
    if "pattern" not in spec:
        raise ProfileError(f"{source}: `versions.{which}` needs a `pattern` or a `command`")
    match = re.search(spec["pattern"], text, re.M)
    return match.group(1) if match else None


# --------------------------------------------------------------------------
# `get`: one key, as shell wants it
# --------------------------------------------------------------------------

# The keys a `hooks.*` block may carry; the shell that reads a block takes each by
# name, so a misspelt one would be ignored and its check would run as if unset.
HOOK_KEYS = {
    "hooks.pre_commit": {"name", "staged", "requires_file", "requires_command", "command",
                         "refusal", "fix"},
    "hooks.check_docs": {"name", "command"},
}


def _refuse_unknown_hook_keys(key: str, value: Any, where: str) -> None:
    for number, block in enumerate(value, 1):
        unknown = sorted(set(block) - HOOK_KEYS[key]) if isinstance(block, dict) else []
        if unknown:
            raise ProfileError(f"{where} has {'an unknown key' if len(unknown) == 1 else 'unknown keys'} "
                               f"{', '.join('`' + u + '`' for u in unknown)} in `{key}` entry {number}; "
                               f"it takes {', '.join(sorted(HOOK_KEYS[key]))}")


def lookup(key: str, root: Path | None = None) -> Any:
    first, _, rest = key.partition(".")
    if first == PROFILE_PREFIX:
        if not rest:
            raise ProfileError("`profile` needs a key after it, e.g. profile.identity.repository")
        return Section(application_profile(root), f"the programme profile {profile_path(root)}",
                       f"{PROFILE_PREFIX}.").get(rest)
    if first in PROGRAMME_SECTIONS:
        return programme_file(root).get(key)
    found = technical(root).get(key)
    if key in HOOK_KEYS and isinstance(found, list):
        _refuse_unknown_hook_keys(key, found, f"the technical profile {technical_path(root)}")
    return found


def render(value: Any) -> list[str]:
    """A value as lines: a string as it is, a list one line per item, and a list
    of tables one block per table: a `name=value` line for each of its keys, then
    an empty line. Shell reads a block by name, so reordering keys in the file or
    leaving a value empty cannot shift what another key means."""
    if isinstance(value, bool):
        return ["true" if value else "false"]
    if isinstance(value, (str, int, float)):
        return [str(value)]
    if isinstance(value, list):
        lines = []
        for item in value:
            if isinstance(item, dict):
                lines.extend(f"{name}={str(v).replace(chr(10), ' ')}" for name, v in item.items())
                lines.append("")
            else:
                lines.append(str(item))
        return lines
    raise ProfileError("that key is a table: ask for one of its keys")
