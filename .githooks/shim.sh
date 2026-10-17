# shim.sh — what each git hook in this folder does, sourced by them. Not a hook.
#
# **The hooks are the programme's** (#485), in the `programme/` submodule, and
# these three files are a shim in front of them. `core.hooksPath` is `.githooks`
# here, a path that exists in every checkout, because `programme/.githooks` does
# not exist until the submodule is initialised: git then finds no hook, runs
# none, and says nothing, which is how an unstamped commit went through in a
# fresh worktree. A shim cannot be missing and cannot be silent. It
#
#   1. points the submodule's own `core.hooksPath` at the programme's refusing
#      hook (`.githooks/in-submodule`), every time, because a submodule has a
#      git configuration of its own and a fresh or re-created one has none;
#   2. warns, and goes on, when the submodule is not at the commit this
#      repository records for it ("run git submodule update"): the hooks that
#      run are then not the ones the pin names;
#   3. runs the programme's hook of the same name with the same arguments and
#      standard input, or, when it is not there, refuses with the way out. A
#      post-merge hook only warns: the merge has happened, and nothing can be
#      refused after it.
#
# Everything with a rule in it is in the programme's hook; this holds none.

# programme_hook <name> [args...]: never returns.
programme_hook() {
  local name="$1" root hook recorded here
  shift
  # The top of the checkout git is running the hook for, which git makes the
  # working directory: not this file's own place, which under an absolute
  # `core.hooksPath` (the live checkout's `<root>/.githooks`) is another checkout's.
  root="$(env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  hook="$root/programme/.githooks/$name"

  # git sets GIT_DIR, GIT_INDEX_FILE and the like for a hook, which would point
  # a git command in the submodule at this repository.
  _sub_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX git -C "$root/programme" "$@"; }

  if [ ! -x "$hook" ]; then
    if [ -e "$root/programme/.git" ]; then
      # Initialised, but at a commit without these hooks: a checkout that did not
      # move the submodule with the pin.
      printf '%s: programme/ is at %s, not the commit this repository records, and that has no .githooks/%s: run git submodule update\n' \
        "$name" "$(_sub_git rev-parse --short HEAD 2>/dev/null || echo '?')" "$name" >&2
    else
      printf '%s: the programme submodule is not initialised: run git submodule update --init\n' "$name" >&2
    fi
    if [ "$name" = post-merge ]; then exit 0; fi
    printf '  (%s is the programme'"'"'s hook, programme/.githooks/%s, and this repository'"'"'s commits are checked by it.\n  --no-verify skips it, if you are sure.)\n' "$name" "$name" >&2
    exit 1
  fi

  if [ -d "$root/programme/.githooks/in-submodule" ] \
     && [ "$(_sub_git config --get core.hooksPath 2>/dev/null || true)" != .githooks/in-submodule ]; then
    _sub_git config core.hooksPath .githooks/in-submodule 2>/dev/null || true
  fi

  # What this repository records for programme/: the index's, which is what is
  # about to be committed (a commit that moves the pin has its new value there),
  # else HEAD's.
  recorded="$(git -C "$root" ls-files -s -- programme 2>/dev/null | awk '$1 == "160000" { print $2; exit }')"
  [ -n "$recorded" ] || recorded="$(git -C "$root" rev-parse --verify --quiet HEAD:programme 2>/dev/null || true)"
  here="$(_sub_git rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$recorded" ] && [ -n "$here" ] && [ "$recorded" != "$here" ]; then
    printf 'warning: programme/ is at %s and this repository records %s: run git submodule update\n' \
      "${here:0:9}" "${recorded:0:9}" >&2
  fi

  exec "$hook" "$@"
}
