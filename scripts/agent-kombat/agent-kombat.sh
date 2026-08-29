#!/usr/bin/env bash
#
# agent-kombat -- multi-model adversarial plan debate.
#
# Ported from https://github.com/kaushikgopal/agent-kombat
#   upstream branch: master
#   upstream SHA:    1a034dd56708532732f0734ea1073ad8a943fc5a  (2462 lines)
#
# Upstream hardcodes exactly two debaters (agent1=claude, agent2=codex) and a
# judge that is also claude. This port makes the roster data: N debaters plus a
# judge and synthesizer, each bound to an arbitrary (harness, model) pair by a
# JSON preset under rosters/. See UPSTREAM.md for the full divergence ledger --
# every deliberate difference from upstream is numbered there (D1..D17), and
# UPSTREAM.md also records how to re-diff this file against upstream.
#
# An entry point plus sourced libraries under _lib/ (see the source block
# below). UPSTREAM.md records why the original single-file decision was
# reversed.
#
set -euo pipefail

# Fail early and legibly rather than with a confusing syntax error. This port
# needs associative arrays (bash 4.0+). `wait -n` is deliberately NOT used, which
# is what keeps the floor at 4.0 rather than 4.3. macOS still ships bash
# 3.2 at /bin/bash, so a machine without a modern bash first on PATH would
# otherwise die deep inside roster parsing with no clue why.
if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  printf 'error: agent-kombat.sh requires bash >= 4.0 (associative arrays); running %s\n' \
    "${BASH_VERSION:-unknown}" >&2
  printf 'hint: macOS ships bash 3.2 at /bin/bash. Install a modern bash (brew install bash)\n' >&2
  printf '      and make sure its directory precedes /bin in PATH.\n' >&2
  exit 1
fi

VERSION="0.2.0"
UPSTREAM_SHA="1a034dd56708532732f0734ea1073ad8a943fc5a"

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SCRIPT_SOURCE" ]]; do
  SCRIPT_DIR_CANDIDATE="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" = /* ]] || SCRIPT_SOURCE="$SCRIPT_DIR_CANDIDATE/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# shellcheck disable=SC2034  # read by resolve_roster_path/load_roster in _lib/roster.sh
ROSTER_DIR="$SCRIPT_DIR/rosters"
# shellcheck disable=SC2034  # read by load_contract in _lib/contracts.sh
CONTRACT_DIR="$SCRIPT_DIR/contracts"
# shellcheck disable=SC2034  # read by prepare_shared_context in _lib/prompts.sh
CONTEXT_FILE="${AGENT_KOMBAT_CONTEXT_FILE:-$SCRIPT_DIR/context/shared-context.md}"

# ---------------------------------------------------------------------------
# Runtime options
# ---------------------------------------------------------------------------

# Three debaters by default: claude, codex and opencode/DeepSeek, which is the whole
# point of the tool -- heterogeneous models fail differently. Briefly defaulted to
# the 2-harness `pair` while opencode's read-only agent looked unavailable; that
# turned out to be a flaky `opencode agent list`, not a flaky `opencode run`
# (see UPSTREAM.md, "opencode agent discovery"). `pair` remains the fallback for
# a machine with no working opencode.
# shellcheck disable=SC2034  # read by load_roster in _lib/roster.sh
DEFAULT_ROSTER="trio-debate"

# The ONLY opencode agent a roster may name. Requiring merely *some* agent is not
# a guarantee -- a roster naming a builtin like `build` gets {"*": "allow"}, i.e.
# bash and writes. Enforced by validate_roster.
# shellcheck disable=SC2034  # read by validate_roster in _lib/roster.sh
REQUIRED_OPENCODE_AGENT="kombat-debater"

ROSTER_NAME=""
ROSTER_FILE=""
# shellcheck disable=SC2034  # read by validate_roster/print_roster in _lib/roster.sh and write_config in _lib/persistence.sh
ROSTER_JSON=""
# shellcheck disable=SC2034  # read by validate_roster/print_roster in _lib/roster.sh and write_config in _lib/persistence.sh
ROSTER_SOURCE=""
ROUNDS=""
MAX_EXTRA_ROUNDS=""
WORKDIR=""
DRY_RUN=0
ROSTER_CHECK=0
CHECK_HARNESSES=0
NO_COLOR_FLAG=0
NO_JUDGE=0
ALLOW_UNSTRUCTURED_JUDGE=0
SHOW_WORKDIR=""
RESUME_WORKDIR=""
REQUIREMENT_FILE=""
CONTRACT_SPEC="plan"
REQUIREMENT=""

DEBUG_AGENT_CALLS="${AGENT_KOMBAT_DEBUG_AGENT_CALLS:-0}"
HEARTBEAT_INTERVAL="${AGENT_KOMBAT_HEARTBEAT_SECONDS:-10}"
# D8: upstream defaults the watchdog OFF (0). We default it on, because opencode
# offers no timeout mechanism of its own -- a wedged opencode turn would otherwise
# block the whole run forever. Per-slot rosters can raise it.
DEFAULT_IDLE_TIMEOUT="${AGENT_KOMBAT_AGENT_IDLE_TIMEOUT_SECONDS:-900}"
# shellcheck disable=SC2034  # read by guard_argv_size in _lib/adapters.sh
MAX_ARGV_BYTES="${AGENT_KOMBAT_MAX_ARGV_BYTES:-400000}"
MAX_EXPANSION_BYTES="${AGENT_KOMBAT_MAX_EXPANSION_BYTES:-262144}"
# A debater that makes more read-like tool calls than this in one turn is
# likely stuck in a read loop. The driver warns (does not fail) -- the turn
# may still produce valid JSON after all that reading.
# shellcheck disable=SC2034  # read by warn_read_heavy_turn in _lib/adapters.sh and write_config in _lib/persistence.sh
MAX_READS_PER_TURN="${AGENT_KOMBAT_MAX_READS_PER_TURN:-20}"
# A debater that makes more read-like tool calls than this in one turn is
# hard-killed mid-turn by the watchdog -- unlike MAX_READS_PER_TURN, which only
# warns post-hoc. opencode streams tool_use events to .raw progressively, so a
# read loop is detectable while it is still running; this is the threshold that
# stops it in seconds instead of letting it burn the whole wall-clock budget.
# shellcheck disable=SC2034  # read by par_run in _lib/dispatch.sh
HARD_READ_LIMIT="${AGENT_KOMBAT_HARD_READ_LIMIT:-60}"

# Per-slot model overrides collected from --model <slot>=<model>.
declare -A MODEL_OVERRIDE=()

# --- sourced libraries ------------------------------------------------------
# Resolved from SCRIPT_DIR (BASH_SOURCE-derived, symlink-walked above) rather
# than $0 or $PWD: the unit tests source this file via `bash -c`, where $0 is
# `bash`, and the driver is invoked from the repo root, from worktrees and via
# make. These must stay above the AGENT_KOMBAT_LIB_ONLY guard at the bottom --
# the tests source this file to call individual functions.
# shellcheck source=_lib/common.sh
source "$SCRIPT_DIR/_lib/common.sh"
# shellcheck source=_lib/roster.sh
source "$SCRIPT_DIR/_lib/roster.sh"
# shellcheck source=_lib/adapters.sh
source "$SCRIPT_DIR/_lib/adapters.sh"
# shellcheck source=_lib/contracts.sh
source "$SCRIPT_DIR/_lib/contracts.sh"
# shellcheck source=_lib/safety.sh
source "$SCRIPT_DIR/_lib/safety.sh"
# shellcheck source=_lib/persistence.sh
source "$SCRIPT_DIR/_lib/persistence.sh"
# shellcheck source=_lib/preflight.sh
source "$SCRIPT_DIR/_lib/preflight.sh"
# shellcheck source=_lib/prompts.sh
source "$SCRIPT_DIR/_lib/prompts.sh"
# shellcheck source=_lib/dispatch.sh
source "$SCRIPT_DIR/_lib/dispatch.sh"
# shellcheck source=_lib/orchestration.sh
source "$SCRIPT_DIR/_lib/orchestration.sh"
# shellcheck source=_lib/runmodes.sh
source "$SCRIPT_DIR/_lib/runmodes.sh"

usage() {
  cat <<'USAGE'
Usage:
  agent-kombat.sh [options] "requirement"
  agent-kombat.sh --roster-check [--roster NAME]
  agent-kombat.sh --check-harnesses
  agent-kombat.sh --show WORKDIR
  agent-kombat.sh --resume WORKDIR

Roster:
      --roster NAME        Roster preset (default: trio-debate). Searched in
                           ./.agent-kombat/rosters/ then <script>/rosters/
      --roster-file PATH   Explicit roster JSON, no search
      --model SLOT=MODEL   Override one slot's model (repeatable)
      --roster-check       Validate the roster and exit; no agent calls
      --allow-unstructured-judge
                           Permit a judge slot without native structured output.
                           Unsafe: the judge's `recommendation` drives control
                           flow, so a parse miss silently changes behaviour.

Debate:
  -r, --rounds N           Debate rounds after round 0 (roster default, else 2)
  -m, --max-extra N        Maximum judge-requested replay rounds (default: 1)
      --no-judge           Skip judge and replay entirely
      --contract SPEC      plan | artifact | path to a contract JSON
      --requirement-file F Read the requirement from a file

Output:
  -d, --workdir DIR        Debate artifact directory. MUST be under <repo>/tmp/
      --show WORKDIR       Print the state of an existing debate directory
      --resume WORKDIR      Resume an interrupted debate

Diagnostics:
      --dry-run            Write config, schemas and every prompt; call nothing
      --check-harnesses    Verify each CLI still has the flags we depend on
      --debug-agent-calls  Write provider debug logs beside raw artifacts
      --heartbeat-interval N   Seconds between status lines (default: 10)
      --agent-idle-timeout N   Default per-slot no-output budget (default: 900)
      --no-color           Disable ANSI colour
  -h, --help               Show this help
      --version            Show version and the pinned upstream SHA

Environment:
  AGENT_KOMBAT_ROSTER            Roster preset name (default: trio-debate)
  AGENT_KOMBAT_MODEL_<SLOT_ID>   Per-slot model override (SLOT_ID uppercased,
                                 '-' replaced by '_')
  AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR=1
                                 Permit a workdir outside <repo>/tmp/
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  local requirement_words=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r | --rounds)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        parse_uint "$1" "$2"
        # shellcheck disable=SC2034  # read by run_debate_loop in _lib/orchestration.sh
        ROUNDS="$2"
        shift 2
        ;;
      -m | --max-extra)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        parse_uint "$1" "$2"
        # shellcheck disable=SC2034  # read by run_judge_loop in _lib/orchestration.sh
        MAX_EXTRA_ROUNDS="$2"
        shift 2
        ;;
      -d | --workdir)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        WORKDIR="$2"
        shift 2
        ;;
      --roster)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        ROSTER_NAME="$2"
        shift 2
        ;;
      --roster-file)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        ROSTER_FILE="$2"
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "$1 requires SLOT=MODEL"
        [[ "$2" == *=* ]] || die "--model expects SLOT=MODEL, got: $2"
        # shellcheck disable=SC2034  # read by apply_model_overrides in _lib/roster.sh
        MODEL_OVERRIDE["${2%%=*}"]="${2#*=}"
        shift 2
        ;;
      --contract)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        # shellcheck disable=SC2034  # read by load_contract in _lib/contracts.sh
        CONTRACT_SPEC="$2"
        shift 2
        ;;
      --requirement-file)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REQUIREMENT_FILE="$2"
        shift 2
        ;;
      --show)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        SHOW_WORKDIR="$2"
        shift 2
        ;;
      --resume)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        RESUME_WORKDIR="$2"
        shift 2
        ;;
      --heartbeat-interval)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        parse_uint "$1" "$2"
        # shellcheck disable=SC2034  # read by par_run in _lib/dispatch.sh and write_config in _lib/persistence.sh
        HEARTBEAT_INTERVAL="$2"
        shift 2
        ;;
      --agent-idle-timeout)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        parse_uint "$1" "$2"
        # shellcheck disable=SC2034  # read by slot_idle_timeout in _lib/dispatch.sh and write_config in _lib/persistence.sh
        DEFAULT_IDLE_TIMEOUT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --roster-check)
        ROSTER_CHECK=1
        shift
        ;;
      --check-harnesses)
        CHECK_HARNESSES=1
        shift
        ;;
      --no-judge)
        # shellcheck disable=SC2034  # read by run_judge_loop in _lib/orchestration.sh
        NO_JUDGE=1
        shift
        ;;
      --allow-unstructured-judge)
        # shellcheck disable=SC2034  # read by validate_roster in _lib/roster.sh
        ALLOW_UNSTRUCTURED_JUDGE=1
        shift
        ;;
      --debug-agent-calls)
        # shellcheck disable=SC2034  # read by adapter_claude in _lib/adapters.sh and write_config in _lib/persistence.sh
        DEBUG_AGENT_CALLS=1
        shift
        ;;
      --no-color)
        # shellcheck disable=SC2034  # read by init_color in _lib/common.sh
        NO_COLOR_FLAG=1
        shift
        ;;
      --version)
        printf 'agent-kombat.sh %s (ported from upstream %s)\n' "$VERSION" "$UPSTREAM_SHA"
        exit 0
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          requirement_words+=("$1")
          shift
        done
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        requirement_words+=("$1")
        shift
        ;;
    esac
  done
  if [[ "${#requirement_words[@]}" -gt 0 ]]; then
    REQUIREMENT="${requirement_words[*]}"
  fi
}

validate_runtime_options() {
  [[ -z "$ROSTER_NAME" || -z "$ROSTER_FILE" ]] \
    || die "--roster and --roster-file are mutually exclusive"
  [[ -z "$SHOW_WORKDIR" || -z "$RESUME_WORKDIR" ]] \
    || die "--show and --resume are mutually exclusive"
  if [[ -n "$REQUIREMENT_FILE" && -n "$REQUIREMENT" ]]; then
    die "pass a requirement either positionally or via --requirement-file, not both"
  fi
}

load_requirement_file() {
  [[ -n "$REQUIREMENT_FILE" ]] || return 0
  [[ -f "$REQUIREMENT_FILE" ]] || die "requirement file not found: $REQUIREMENT_FILE"
  REQUIREMENT="$(cat "$REQUIREMENT_FILE")"
}

# Expand `@path` references in the requirement into inlined file contents.
#
# Kept from upstream (L571/L582) because a requirement will absolutely want to
# say `@docs/architecture/foo.md`, but HARDENED: upstream expands whatever path
# it is handed. Here absolute paths and `..` traversal are refused, and total
# expansion is capped -- the requirement text ends up inside a prompt sent to
# three external models, so it is a data-exfiltration surface, not just a
# convenience.
expand_prompt_file_refs() {
  [[ -n "$REQUIREMENT" ]] || return 0
  [[ "$REQUIREMENT" == *@* ]] || return 0

  local expanded="$REQUIREMENT"
  local total=0
  local ref
  local refs
  # Physical repo root: both sides of the containment comparison must be resolved,
  # or a symlinked component in REPO_ROOT itself makes every path look external.
  local repo_phys
  repo_phys="$(cd -P "$REPO_ROOT" 2>/dev/null && pwd -P)" || repo_phys="$REPO_ROOT"
  repo_phys="${repo_phys%/}"
  # Sorted LONGEST FIRST. `${expanded//"$ref"/...}` is a substring replace, so with
  # both @docs/a and @docs/ab present, expanding @docs/a first would also rewrite
  # the @docs/a prefix *inside* @docs/ab and corrupt it. Replacing the longer ref
  # first removes it from the text before the shorter one is ever considered.
  refs="$(printf '%s\n' "$REQUIREMENT" | grep -oE '(^|[[:space:]])@[A-Za-z0-9_./-]+' | sed 's/^[[:space:]]*//' | sort -u | awk '{ print length, $0 }' | sort -rn -k1,1 | cut -d" " -f2- || true)"
  [[ -n "$refs" ]] || return 0

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    local path="${ref#@}"
    if [[ "$path" = /* ]]; then
      warn "refusing absolute path in requirement reference: $ref"
      continue
    fi
    if [[ "$path" == *..* ]]; then
      warn "refusing parent-directory traversal in requirement reference: $ref"
      continue
    fi
    # Neither check above looks at symlinks, and both are text checks on the
    # reference itself: `@docs/notes`, where docs/notes links to /etc/passwd or
    # ../.env, has no leading `/` and no `..`, and `cat` follows it. So resolve
    # the parent physically, refuse a symlinked leaf, and require the result to
    # stay under the repo -- the same containment enforce_workdir_location
    # applies to the workdir. The repo tracks zero symlinks, so refusing them
    # outright costs nothing legitimate and needs no chain-walking.
    local ref_dir ref_base resolved
    ref_dir="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P)" || {
      warn "requirement reference directory does not resolve, leaving literal: $ref"
      continue
    }
    ref_base="$(basename "$path")"
    resolved="${ref_dir%/}/$ref_base"
    if [[ -L "$resolved" ]]; then
      warn "refusing symlinked requirement reference (a symlink can point anywhere on disk): $ref"
      continue
    fi
    if [[ "$resolved" != "$repo_phys/"* ]]; then
      warn "refusing requirement reference outside the repository: $ref resolves to $resolved"
      continue
    fi
    # Containment is not enough on its own: the repo's own .env is inside the
    # repo. This function's output is shipped to three external model providers,
    # so refuse secret-shaped names regardless of where they live.
    case "$ref_base" in
      .env | .env.* | *.env | *.pem | *_rsa | *_dsa | *_ed25519 | id_* | *credentials* | *.key | *.p12 | *.pfx | *.tfstate | *.tfvars)
        warn "refusing secret-shaped requirement reference: $ref"
        continue
        ;;
    esac
    if [[ ! -f "$resolved" ]]; then
      warn "requirement reference not found, leaving literal: $ref"
      continue
    fi
    local size
    size="$(file_size_bytes "$resolved")"
    total="$((total + size))"
    if [[ "$total" -gt "$MAX_EXPANSION_BYTES" ]]; then
      die "requirement file expansion exceeds ${MAX_EXPANSION_BYTES} bytes at $ref; inline less or split the debate"
    fi
    local body
    body="$(cat "$resolved")"
    expanded="${expanded//"$ref"/$'\n---BEGIN '"$path"$'---\n'"$body"$'\n---END '"$path"$'---\n'}"
    info "expanded requirement reference $ref (${size} bytes)"
  done <<<"$refs"

  REQUIREMENT="$expanded"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_runtime_options
  init_color
  preflight_jq
  detect_repo_root

  if [[ -n "$SHOW_WORKDIR" ]]; then
    show_debate "$SHOW_WORKDIR"
    exit 0
  fi

  if [[ -n "$RESUME_WORKDIR" ]]; then
    resume_run "$RESUME_WORKDIR"
    exit 0
  fi

  load_requirement_file
  expand_prompt_file_refs
  load_contract
  load_roster

  if [[ "$ROSTER_CHECK" -eq 1 ]]; then
    print_roster
    ok "roster '$(roster_get '.id // "?"')' is valid"
    exit 0
  fi

  if [[ "$CHECK_HARNESSES" -eq 1 ]]; then
    run_check_harnesses
    exit 0
  fi

  [[ -n "$REQUIREMENT" ]] \
    || die "missing requirement: pass it positionally or via --requirement-file"

  local target
  target="${WORKDIR:-$(default_workdir)}"
  enforce_workdir_location "$target"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ ! -e "$target" ]] || die "workdir already exists: $target"
    run_dry "$target"
    exit 0
  fi

  preflight_tools
  create_debate_skeleton "$target"
  print_roster
  printf '\n'

  run_round0 "$target"
  run_debate_loop "$target"
  run_judge_loop "$target"
  run_synthesis "$target"
  print_final_report "$target"
}

# Sourcing this file with AGENT_KOMBAT_LIB_ONLY=1 defines every function without
# running anything, so the unit tests can call individual functions directly
# instead of only through the CLI. Every `source` line above sits above this
# guard, so sourcing the entry point this way brings in every _lib/ function
# too.
if [[ "${AGENT_KOMBAT_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
