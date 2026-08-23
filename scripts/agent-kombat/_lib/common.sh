# shellcheck shell=bash
# agent-kombat -- Output helpers, file and process helpers, and the JSONL event log.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: COLOR_RESET, COLOR_DIM, COLOR_RED, COLOR_GREEN, COLOR_YELLOW,
#   COLOR_BLUE (moved here per Ruling 2 -- declared here, written by
#   init_color here, read by the output helpers here: die, refuse, info,
#   step, ok, warn).
# Reads globals owned elsewhere: NO_COLOR_FLAG (entry file, parse_args --
#   read only by init_color here), SLOT_ORDER (roster.sh, index_roster_slots
#   -- read only by merge_round_events here)

# Guard against double-sourcing.
[ -n "${_AK_COMMON_SOURCED:-}" ] && return 0
_AK_COMMON_SOURCED=1

COLOR_RESET=""
COLOR_DIM=""
COLOR_RED=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_BLUE=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

die() {
  printf '%serror:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
  exit 1
}

# Exit 2 is reserved for "the run was refused or did not converge", so a caller
# can tell a validation refusal apart from a setup error.
refuse() {
  printf '%srefused:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
  exit 2
}

info() { printf '%s%s%s\n' "$COLOR_DIM" "$*" "$COLOR_RESET"; }
step() { printf '%s==>%s %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"; }
ok() { printf '%sok:%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
warn() { printf '%swarn:%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

init_color() {
  if [[ "$NO_COLOR_FLAG" -eq 1 || -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    return
  fi
  COLOR_RESET=$'\033[0m'
  COLOR_DIM=$'\033[2m'
  COLOR_RED=$'\033[31m'
  COLOR_GREEN=$'\033[32m'
  COLOR_YELLOW=$'\033[33m'
  COLOR_BLUE=$'\033[34m'
}

# ---------------------------------------------------------------------------
# File and process helpers
# ---------------------------------------------------------------------------

file_size_bytes() {
  local file="$1"
  [[ -e "$file" ]] || {
    printf '0\n'
    return
  }
  # A `stat -f%z || stat -c%s` chain is NOT portable, and it fails in the worst
  # way. On GNU, `-f` means --file-system: it exits 1 *after* printing a multi-line
  # "File: ... Blocks: ..." report to STDOUT, so `2>/dev/null` hides nothing and
  # the successful fallback's number gets appended to that garbage. The caller then
  # does $((total + size)) on it and dies with "File: unbound variable" under
  # `set -u`. Callers feed this into arithmetic and size guards, so validate the
  # value rather than trusting an exit status.
  local size
  size="$(stat -c '%s' "$file" 2>/dev/null || true)"
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    size="$(stat -f '%z' "$file" 2>/dev/null || true)"
  fi
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    # Neither stat dialect: wc is in POSIX and always available.
    size="$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s\n' "$size"
}

file_mtime_epoch() {
  local file="$1"
  [[ -e "$file" ]] || {
    printf '0\n'
    return
  }
  # Same dialect-probing shape as file_size_bytes above, and for the same
  # reason: `stat -f '%m' FILE` on GNU coreutils means --file-system, which
  # prints a filesystem report to stdout AND exits non-zero, so a BSD-first
  # `||` chain concatenates that report with the GNU result. Probe GNU first
  # (BSD stat rejects -c with no stdout) and validate the value rather than
  # trusting an exit status.
  local mtime
  mtime="$(stat -c '%Y' "$file" 2>/dev/null || true)"
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    mtime="$(stat -f '%m' "$file" 2>/dev/null || true)"
  fi
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  printf '%s\n' "$mtime"
}

format_duration() {
  local seconds="$1"
  printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
}

sha256_file() {
  if [[ -e "$1" ]]; then
    # shasum (perl, ships with macOS) and sha256sum (coreutils) are not both
    # present on every host; manifests carry these digests, so falling back
    # matters rather than emitting an empty field.
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" | awk '{print $1}'
    else
      printf 'unavailable\n'
    fi
  else
    printf 'absent\n'
  fi
}

# Upstream's write_atomic. Kept (not simplified away): --resume correctness
# depends on config.json never being observed half-written, and a Ctrl-C during
# a plain `jq > file` truncates it and makes an expensive workdir unresumable.
write_atomic() {
  local target="$1"
  local tmp
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  cat >"$tmp"
  mv "$tmp" "$target"
}

abs_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$PWD" "$path"
  fi
}

# Collapse `.`, `..` and duplicate slashes in an absolute path, WITHOUT requiring
# the path to exist -- the workdir is validated before it is created.
#
# `realpath`/`readlink -f` are not portable enough here (macOS `realpath` predates
# --canonicalize-missing on some installs), and a purely lexical collapse is
# actually what the containment check wants: it must not be fooled by a symlink
# that appears later either. Any comparison against an UNNORMALISED path is
# bypassable with `..` -- see enforce_workdir_location.
normalise_path() {
  local path="$1"
  local part
  # Named _np_parts, not `out`: shellcheck tracks variable types by NAME across
  # the whole file, so reusing a common name like `out` as an array here makes it
  # flag every unrelated string `out=` elsewhere (SC2178/SC2128).
  local -a _np_parts=()
  local IFS='/'
  for part in $path; do
    case "$part" in
      '' | '.') continue ;;
      '..')
        # Popping past the root is clamped rather than wrapping around.
        # Index-based (not `_np_parts[-1]`): negative array subscripts need
        # Bash 4.3+, but the startup guard above only requires Bash 4.0+.
        # The index is computed inline rather than via a temporary: a temp read
        # only from inside a quoted `unset` subscript is invisible to shellcheck,
        # which then reports it as unused (SC2034) and fails the scoped hook.
        if [[ "${#_np_parts[@]}" -gt 0 ]]; then
          unset "_np_parts[$((${#_np_parts[@]} - 1))]"
        fi
        ;;
      *) _np_parts+=("$part") ;;
    esac
  done
  printf '/%s\n' "$(
    IFS='/'
    printf '%s' "${_np_parts[*]:-}"
  )"
}

# Recursive process-tree kill.
#
# Divergence from upstream (L189), and a necessary one: upstream's
# kill_process_tree only reaches DIRECT children (`pkill -TERM -P "$pid"`),
# which is sufficient there because its child IS the harness process. Here the
# child is a subshell wrapping an adapter, so the harness is a grandchild and
# would survive a direct-children-only kill -- leaving an orphaned `claude`,
# `codex` or `opencode` burning tokens after a timeout.
kill_process_tree() {
  local pid="$1"
  local sig="${2:-TERM}"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_process_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

terminate_process_tree() {
  local pid="$1"
  kill_process_tree "$pid" TERM
  # Give the tree a moment to unwind before escalating.
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt 20 ]]; do
    sleep 0.1
    waited="$((waited + 1))"
  done
  kill_process_tree "$pid" KILL
}

parse_uint() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer"
}

# ---------------------------------------------------------------------------
# Event log
# ---------------------------------------------------------------------------
#
# D13. Upstream appends every event to one events.jsonl, which is safe because
# it dispatches agents sequentially. This port dispatches a round's slots
# concurrently, and two writers matter:
#
#   * the parent poll loop, and
#   * each adapter child, which emits its own events (the fenced-JSON re-ask
#     loop runs inside the child).
#
# Concurrent appends can interleave mid-line, and macOS ships no flock(1). So
# each slot gets its own event file, written by the child while it lives and by
# the parent only after it is dead, and the round barrier merges them into
# events.jsonl in roster-then-timestamp order. That also makes the ordering
# deterministic, which is what lets smoke.sh assert on the event sequence at
# all.

log_event_file() {
  local file="$1"
  local event="$2"
  # Not "${3:-{}}": brace expansion inside a default makes that unreliable.
  local fields='{}'
  if [[ $# -ge 3 ]]; then
    fields="$3"
  fi
  jq -cn \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg event "$event" \
    --argjson fields "$fields" \
    '{ts: $ts, event: $event} + $fields' >>"$file"
}

log_event() {
  local target="$1"
  shift
  log_event_file "$target/events.jsonl" "$@"
}

# Merge the per-slot event files for one round into events.jsonl, ordered by
# roster position and then timestamp. Deterministic regardless of which slot
# finished first.
merge_round_events() {
  local target="$1"
  local round="$2"
  local position=0
  local slot
  local slot_file
  local merged="$target/rounds/r${round}.events-merged.jsonl"
  : >"$merged"
  # `"${arr[@]}"` on an EMPTY array is an unbound-variable error under `set -u` in
  # bash 4.0-4.3. Bash 4.4+ tolerates it, and the startup guard only requires 4.0,
  # so the emptiness has to be checked rather than assumed.
  [[ "${#SLOT_ORDER[@]}" -gt 0 ]] || return 0
  for slot in "${SLOT_ORDER[@]}"; do
    slot_file="$target/rounds/r${round}-${slot}.events.jsonl"
    [[ -f "$slot_file" ]] || continue
    jq -c --argjson pos "$position" --arg slot "$slot" \
      '. + {slot: $slot, _roster_position: $pos}' "$slot_file" >>"$merged"
    position="$((position + 1))"
  done
  [[ -s "$merged" ]] || return 0
  jq -sc 'sort_by(._roster_position, .ts) | .[] | del(._roster_position)' "$merged" \
    >>"$target/events.jsonl"
  rm -f "$merged"
}
