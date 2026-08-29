# shellcheck shell=bash
# agent-kombat -- Workdir containment and the read-only working-tree guard.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: REPO_ROOT (declared at file top level here. WRITTEN only by
#   detect_repo_root here. Read here by default_workdir, enforce_workdir_location
#   and tree_state; also read by expand_prompt_file_refs in the entry file,
#   and by write_config in _lib/persistence.sh -- neither of those two writes
#   it, so this file is the sole writer and the declaration moves here with
#   it.)
# Reads globals owned elsewhere: none

# Guard against double-sourcing.
[ -n "${_AK_SAFETY_SOURCED:-}" ] && return 0
_AK_SAFETY_SOURCED=1

REPO_ROOT=""

# ---------------------------------------------------------------------------
# Workdir
# ---------------------------------------------------------------------------

detect_repo_root() {
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$REPO_ROOT" ]] || REPO_ROOT="$PWD"
}

default_workdir() {
  printf '%s/tmp/agent-kombat/debate_%s\n' "$REPO_ROOT" "$(date '+%Y%m%d_%H%M%S')"
}

# D7: upstream merely DEFAULTS its workdir (to .agents/plans/). A default is not
# an enforcement, and in this repo the difference is load-bearing: tmp/ is
# gitignored but .agents/ is NOT, so an upstream-default workdir would drop a
# debate transcript straight into committable territory.
# Resolve a path's DEEPEST EXISTING ancestor through symlinks, then re-append the
# not-yet-created tail. `cd -P` is what does the real work: it resolves every
# symlink component, which a lexical collapse cannot.
#
# Needed because lexical normalisation alone is not containment. Verified escape
# before this existed: `--workdir tmp/aklink/debate`, with tmp/aklink -> a
# directory outside the repo, passed the prefix test and created
# /private/tmp/ak-outside/debate. The old comment claimed the lexical form "cannot
# be fooled by a symlink introduced later", which was simply false -- a symlink
# *parent* defeats it outright.
resolve_through_symlinks() {
  local path="$1"
  local tail=""
  while [[ ! -e "$path" && "$path" != "/" && -n "$path" ]]; do
    tail="$(basename "$path")${tail:+/$tail}"
    path="$(dirname "$path")"
  done
  local base
  base="$(cd -P "$path" 2>/dev/null && pwd -P)" || {
    printf '%s\n' "$1"
    return 0
  }
  printf '%s\n' "${base%/}${tail:+/$tail}"
}

enforce_workdir_location() {
  local target="$1"
  local resolved
  # NORMALISE before comparing. abs_path only prepends $PWD, so a prefix test
  # against an unnormalised string is trivially bypassable:
  #   --workdir tmp/../../../../private/tmp/x
  # starts with "$PWD/tmp/" and would pass, while actually resolving outside the
  # repo entirely. Verified escaping to <repo>/private/tmp before this fix.
  resolved="$(normalise_path "$(abs_path "$target")")"

  # Belt and braces: reject a literal parent-directory component outright, so the
  # refusal does not depend on realpath semantics for a not-yet-existing path.
  case "/$target/" in
    */../*) die "workdir must not contain a '..' component: $target" ;;
  esac

  if [[ "$resolved" == *"/.agents/"* ]]; then
    die "refusing workdir under .agents/: that is upstream's default, but .agents/ is NOT gitignored in this repo, so debate artifacts there would be committable. Use $REPO_ROOT/tmp/ instead."
  fi

  if [[ "${AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR:-0}" == "1" ]]; then
    warn "AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR=1: skipping the tmp/ containment check for $resolved"
    return 0
  fi

  # Compare CANONICAL paths on both sides. A lexical prefix test is not
  # containment: with tmp/aklink -> outside the repo, `tmp/aklink/debate`
  # normalises to a string under $REPO_ROOT/tmp and then writes outside it.
  # Verified: that exact input created /private/tmp/ak-outside/debate.
  local tmp_root canonical
  tmp_root="$(resolve_through_symlinks "$REPO_ROOT/tmp")"
  canonical="$(resolve_through_symlinks "$resolved")"
  if [[ "$canonical" != "$tmp_root" && "$canonical" != "$tmp_root"/* ]]; then
    die "workdir must live under $tmp_root (got $target, which resolves to $canonical). Debates are never committed; set AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR=1 only if you know why."
  fi

  # Reject a symlink anywhere in the existing chain even when it currently points
  # inside tmp/. The target of a symlink can be repointed between this check and
  # the writes that follow, so allowing one makes containment a race.
  # Terminate at the UNRESOLVED tmp path too, not only at the resolved one.
  # When $REPO_ROOT/tmp is itself reached via a symlink, $tmp_root is the
  # resolved location, so the walk never matches it and keeps climbing past the
  # repository boundary -- inspecting (and potentially rejecting on) parent
  # directories that have nothing to do with the workdir.
  local tmp_unresolved="$REPO_ROOT/tmp"
  local probe="$resolved"
  while [[ "$probe" != "/" && -n "$probe" && "$probe" != "$tmp_root" && "$probe" != "$tmp_unresolved" ]]; do
    if [[ -L "$probe" ]]; then
      die "workdir path component is a symlink: $probe. Containment cannot be guaranteed through a link whose target may change after this check."
    fi
    probe="$(dirname "$probe")"
  done

  # Do not merely assume tmp/ is ignored -- assert it, so a change to .gitignore
  # cannot quietly turn every future debate into a committable artifact.
  if ! (cd "$REPO_ROOT" && git check-ignore -q tmp 2>/dev/null); then
    die "$tmp_root is not gitignored; refusing to write debate artifacts there. Add '/tmp' to .gitignore (leading slash anchors it to the repo root; no trailing slash, because this check runs before the directory exists and 'tmp/' only matches a directory that is already there)."
  fi
}

# ---------------------------------------------------------------------------
# Read-only guard
# ---------------------------------------------------------------------------
#
# A cheap global backstop that does not depend on any one harness's sandbox
# actually working: after every round, the working tree must look the same as it
# did when the run started. One check, and it catches an opencode permission gap,
# a codex sandbox escape, or a claude --tools regression equally well.
#
# Compared against a BASELINE captured at run start rather than requiring a clean
# tree: a real development checkout is routinely dirty, and a guard that cries
# wolf on every uncommitted file is a guard people disable.
# Snapshot path+status AND CONTENT.
#
# Status pairs alone are not a tamper check: overwriting a file that is already
# ` M`, or replacing an existing `??` file, leaves the porcelain output byte
# identical. So a harness could rewrite any already-dirty file and the backstop
# would report the tree unchanged.
#
# Content is captured as (a) one hash over the full tracked diff and (b) a hash
# per untracked file, both excluding tmp/ since that is where debates legitimately
# write.
tree_state() {
  (
    cd "$REPO_ROOT" || return 0
    git status --porcelain 2>/dev/null | grep -v '^?? tmp/' | LC_ALL=C sort
    printf 'tracked-diff %s\n' \
      "$(git diff HEAD --binary 2>/dev/null | shasum -a 256 | awk '{print $1}')"
    git status --porcelain 2>/dev/null \
      | sed -n 's/^?? //p' | grep -v '^tmp/' | LC_ALL=C sort \
      | while IFS= read -r f; do
          [[ -f "$f" ]] || continue
          printf 'untracked %s %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"
        done
  ) 2>/dev/null || true
}

snapshot_tree_baseline() {
  local target="$1"
  tree_state >"$target/tree-baseline.txt" || true
}

assert_tree_untouched() {
  local target="$1"
  local phase="$2"
  local baseline="$target/tree-baseline.txt"
  # No baseline means we cannot say anything honest about what changed, so say
  # that rather than silently passing.
  if [[ ! -f "$baseline" ]]; then
    warn "no tree baseline recorded; skipping the read-only check for $phase"
    return 0
  fi
  local current
  current="$(mktemp)"
  # Same content-aware snapshot as the baseline, or the comparison is meaningless.
  tree_state >"$current" || true
  local drift
  drift="$(diff "$baseline" "$current" || true)"
  rm -f "$current"
  if [[ -n "$drift" ]]; then
    warn "working tree changed during $phase -- a harness may have escaped its read-only sandbox:"
    printf '%s\n' "$drift" >&2
    log_event "$target" "readonly.violation" "$(jq -n --arg phase "$phase" \
      --arg detail "$(printf '%s' "$drift" | head -20)" '{phase: $phase, detail: $detail}')"
    die "refusing to continue: the debate is plan-only and must not modify the tree. Review the diff above; if it was you and not a harness, re-run with --resume."
  fi
}
