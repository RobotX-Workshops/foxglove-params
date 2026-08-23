# shellcheck shell=bash
# agent-kombat -- Roster resolution, loading, validation and printing.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: DEBATER_IDS, SLOT_ORDER, JUDGE_ID, SYNTH_ID (declared here,
#   written only by index_roster_slots here, which also reads JUDGE_ID and
#   SYNTH_ID back to append them onto SLOT_ORDER. DEBATER_IDS and SLOT_ORDER
#   are also read by validate_roster here; JUDGE_ID is also read by
#   validate_roster and warn_judge_independence here; DEBATER_IDS is also read
#   by warn_judge_independence and print_roster here (print_roster never
#   touches JUDGE_ID). DEBATER_IDS is also read across most later libs
#   (prompts.sh, orchestration.sh, runmodes.sh, and persistence.sh -- by
#   write_round_manifest and publish_round there); JUDGE_ID is also read in
#   prompts.sh and orchestration.sh (not dispatch.sh -- neither global is
#   referenced there); SLOT_ORDER is also read by merge_round_events in
#   common.sh; SYNTH_ID is also read by run_synthesis in orchestration.sh.)
# Reads globals owned elsewhere: ROSTER_NAME (entry file -- read and written
#   here too by load_roster, but validate_runtime_options in the entry file
#   and reconstruct_progress in runmodes.sh also read it, so no single file
#   owns both sides and the declaration stays put), ROSTER_FILE (entry file
#   -- read only here by load_roster; parse_args writes it and
#   validate_runtime_options in the entry file and reconstruct_progress in
#   runmodes.sh read it again), ROSTER_JSON (entry file, empty default --
#   written by load_roster here (the file-path branch and the flag/env/
#   default branch) and again by apply_model_overrides's two rewrite sites
#   here; read by roster_get, roster_slots_json, index_roster_slots, and by
#   apply_model_overrides itself (which reads the prior value before each
#   rewrite) -- NOT by validate_roster or print_roster, which reach it only
#   indirectly through the roster_get / slot_field helpers. Written again by
#   load_run_config in runmodes.sh on --resume, so no single owner),
#   ROSTER_SOURCE (entry file -- written by load_roster here (the
#   file-path branch and the flag/env/default branch); read by
#   validate_roster and print_roster here -- NOT apply_model_overrides,
#   which never references the shell global ROSTER_SOURCE (it touches the
#   unrelated jq field .model_source inside ROSTER_JSON instead). Written
#   again by load_run_config in runmodes.sh on --resume, so no single
#   owner), ROUNDS,
#   MAX_EXTRA_ROUNDS (entry file, parse_args/load_run_config -- read AND
#   conditionally written here too, by load_roster's roster-default fallback
#   when the CLI left them empty; no single file owns both sides, so the
#   declarations stay in the entry file), NO_JUDGE (entry file,
#   parse_args/load_run_config -- read only here, by validate_roster and
#   warn_judge_independence), ALLOW_UNSTRUCTURED_JUDGE (entry file, parse_args
#   -- read only by validate_roster here), ROSTER_DIR (entry file, top-level
#   default -- read only by resolve_roster_path/load_roster here),
#   DEFAULT_ROSTER (entry file, top-level default -- read only by load_roster
#   here), REQUIRED_OPENCODE_AGENT (entry file, top-level default -- read only
#   by validate_roster here), CONTRACT_ID, CONTRACT_NOUN, CONTRACT_SOURCE
#   (contracts.sh, load_contract -- also written by load_run_config in
#   runmodes.sh on --resume; read only by print_roster here), MODEL_OVERRIDE
#   (entry file, parse_args -- read only by
#   apply_model_overrides here), COLOR_RED, COLOR_RESET (common.sh -- read
#   only by validate_roster here)

# Guard against double-sourcing.
[ -n "${_AK_ROSTER_SOURCED:-}" ] && return 0
_AK_ROSTER_SOURCED=1

# ---------------------------------------------------------------------------
# Roster loading, resolution and validation
# ---------------------------------------------------------------------------

# Populated by load_roster / load_run_config.
declare -a DEBATER_IDS=()
declare -a SLOT_ORDER=() # debaters, then judge, then synthesizer
JUDGE_ID=""
SYNTH_ID=""

resolve_roster_path() {
  local name="$1"
  local candidate
  for candidate in "./.agent-kombat/rosters/${name}.json" "$ROSTER_DIR/${name}.json"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# D1: precedence is flag > env > file > default. Upstream inverts this -- its
# CLI flags LOSE to environment variables and to a local config file, which is
# a foot-gun in a repo where `source .env` is routine.
load_roster() {
  local path=""
  if [[ -n "$ROSTER_FILE" ]]; then
    path="$ROSTER_FILE"
    [[ -f "$path" ]] || die "roster file not found: $path"
    ROSTER_SOURCE="file:$path"
  else
    local name="$ROSTER_NAME"
    local origin="flag"
    if [[ -z "$name" ]]; then
      name="${AGENT_KOMBAT_ROSTER:-}"
      origin="env"
    fi
    if [[ -z "$name" ]]; then
      name="$DEFAULT_ROSTER"
      origin="default"
    fi
    path="$(resolve_roster_path "$name")" \
      || die "roster '$name' not found in ./.agent-kombat/rosters/ or $ROSTER_DIR/"
    ROSTER_NAME="$name"
    ROSTER_SOURCE="$origin:$name"
  fi

  jq -e . "$path" >/dev/null 2>&1 || die "roster is not valid JSON: $path"
  ROSTER_JSON="$(jq -c . "$path")"

  apply_model_overrides
  index_roster_slots
  validate_roster

  # Roster-level defaults, still overridable by the CLI flags parsed earlier.
  if [[ -z "$ROUNDS" ]]; then
    ROUNDS="$(roster_get '.rounds // 2')"
  fi
  if [[ -z "$MAX_EXTRA_ROUNDS" ]]; then
    MAX_EXTRA_ROUNDS="$(roster_get '.max_extra_rounds // 1')"
  fi
}

roster_get() {
  printf '%s' "$ROSTER_JSON" | jq -r "$1"
}

# All slots as a flat array of {role, ...slot} objects, in canonical order.
roster_slots_json() {
  printf '%s' "$ROSTER_JSON" | jq -c '
    [ (.debaters[] | . + {role: "debater"}) ]
    + (if .judge then [ .judge + {role: "judge"} ] else [] end)
    + (if .synthesizer then [ .synthesizer + {role: "synthesizer"} ] else [] end)
  '
}

slot_json() {
  local id="$1"
  roster_slots_json | jq -ce --arg id "$id" '.[] | select(.id == $id)' \
    || die "no such slot in roster: $id"
}

slot_field() {
  local id="$1"
  local filter="$2"
  slot_json "$id" | jq -r "$filter"
}

apply_model_overrides() {
  local id
  local env_name
  local value
  local ids
  ids="$(printf '%s' "$ROSTER_JSON" | jq -r '
    [ (.debaters[]?.id), (.judge?.id // empty), (.synthesizer?.id // empty) ] | .[]
  ')"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    value=""
    local source=""
    if [[ -n "${MODEL_OVERRIDE[$id]:-}" ]]; then
      value="${MODEL_OVERRIDE[$id]}"
      source="flag"
    elif [[ "$id" =~ ^[a-z][a-z0-9_-]{0,15}$ ]]; then
      # Only derive an environment variable name from an id that already matches
      # the slot-id pattern. A malformed id (a space, say) would otherwise make
      # bash abort with "invalid variable name" here, BEFORE validate_roster gets
      # to report the real problem with a proper exit code.
      env_name="AGENT_KOMBAT_MODEL_$(printf '%s' "$id" | tr '[:lower:]-' '[:upper:]_')"
      if [[ -n "${!env_name:-}" ]]; then
        value="${!env_name}"
        source="env"
      fi
    fi
    [[ -n "$value" ]] || continue
    ROSTER_JSON="$(printf '%s' "$ROSTER_JSON" | jq -c \
      --arg id "$id" --arg model "$value" --arg source "$source" '
      def patch: if .id == $id then .model = $model | .model_source = $source else . end;
      .debaters |= map(patch)
      | (if .judge then .judge |= patch else . end)
      | (if .synthesizer then .synthesizer |= patch else . end)
    ')"
    info "model override: $id -> $value ($source)"
  done <<<"$ids"

  # An override naming a slot that does not exist was silently ignored, while
  # SKILL.md documents it as a hard error. Honour the documentation: a typo'd slot
  # id otherwise means you believe you swapped a model and you did not.
  local known
  known="$(printf '%s' "$ROSTER_JSON" | jq -r '
    [ (.debaters[]?.id), (.judge?.id // empty), (.synthesizer?.id // empty) ] | .[]
  ')"
  local requested
  for requested in "${!MODEL_OVERRIDE[@]}"; do
    printf '%s\n' "$known" | grep -qxF "$requested" \
      || die "--model names slot '$requested', which is not in roster '$(roster_get '.id // "?"')'. Known slots: $(printf '%s' "$known" | tr '\n' ' ')"
  done

  # Everything not overridden is sourced from the roster file itself.
  ROSTER_JSON="$(printf '%s' "$ROSTER_JSON" | jq -c '
    def mark: if has("model_source") then . else .model_source = "roster" end;
    .debaters |= map(mark)
    | (if .judge then .judge |= mark else . end)
    | (if .synthesizer then .synthesizer |= mark else . end)
  ')"
}

index_roster_slots() {
  DEBATER_IDS=()
  SLOT_ORDER=()
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    DEBATER_IDS+=("$id")
    SLOT_ORDER+=("$id")
  done < <(printf '%s' "$ROSTER_JSON" | jq -r '.debaters[]?.id // empty')

  JUDGE_ID="$(roster_get '.judge.id // ""')"
  SYNTH_ID="$(roster_get '.synthesizer.id // ""')"
  [[ -z "$JUDGE_ID" ]] || SLOT_ORDER+=("$JUDGE_ID")
  [[ -z "$SYNTH_ID" ]] || SLOT_ORDER+=("$SYNTH_ID")
}

validate_roster() {
  local errors=()
  local id
  local harness
  local mode
  local role

  [[ "${#DEBATER_IDS[@]}" -ge 2 ]] \
    || errors+=("roster needs at least 2 debaters, found ${#DEBATER_IDS[@]}")

  # Duplicate slot ids would collide in artifact paths, silently overwriting one
  # participant's plan with another's.
  local dupes
  dupes="$(printf '%s\n' "${SLOT_ORDER[@]}" | sort | uniq -d | tr '\n' ' ')"
  [[ -z "${dupes// /}" ]] || errors+=("duplicate slot ids: $dupes")

  local slots
  slots="$(roster_slots_json)"
  local count
  count="$(printf '%s' "$slots" | jq 'length')"
  local i
  for ((i = 0; i < count; i++)); do
    local slot
    slot="$(printf '%s' "$slots" | jq -c ".[$i]")"
    id="$(printf '%s' "$slot" | jq -r '.id // ""')"
    harness="$(printf '%s' "$slot" | jq -r '.harness // ""')"
    mode="$(printf '%s' "$slot" | jq -r '.structured_output // ""')"
    role="$(printf '%s' "$slot" | jq -r '.role')"

    [[ "$id" =~ ^[a-z][a-z0-9_-]{0,15}$ ]] \
      || errors+=("slot id '$id' must match ^[a-z][a-z0-9_-]{0,15}\$ (artifact paths derive from it)")
    case "$harness" in
      claude | codex | opencode) ;;
      *) errors+=("slot '$id' has unknown harness '$harness' (want claude|codex|opencode)") ;;
    esac
    case "$mode" in
      native | fenced_json) ;;
      none)
        [[ "$role" == "synthesizer" ]] \
          || errors+=("slot '$id' uses structured_output 'none', legal only on a synthesizer")
        ;;
      *) errors+=("slot '$id' has unknown structured_output '$mode'") ;;
    esac
    [[ -n "$(printf '%s' "$slot" | jq -r '.model // ""')" ]] \
      || errors+=("slot '$id' has no model")
    [[ -n "$(printf '%s' "$slot" | jq -r '.label // ""')" ]] \
      || errors+=("slot '$id' has no label")

    if [[ "$harness" == "opencode" ]]; then
      local slot_agent
      slot_agent="$(printf '%s' "$slot" | jq -r '.agent // ""')"
      if [[ -z "$slot_agent" ]]; then
        errors+=("opencode slot '$id' must set 'agent' -- opencode has no read-only sandbox flag, so the agent's permission set is the ONLY thing stopping it writing to the tree")
      elif [[ "$slot_agent" != "$REQUIRED_OPENCODE_AGENT" ]]; then
        # An allowlist, not just a presence check. Requiring *some* agent is not a
        # guarantee: a roster could name a builtin like `build`, whose resolved
        # permissions are {"*": "allow"} (bash and writes enabled), and validation
        # would have happily accepted it.
        errors+=("opencode slot '$id' sets agent '$slot_agent'; only '$REQUIRED_OPENCODE_AGENT' is permitted. Naming any other agent -- e.g. a builtin like 'build' -- would hand a debater write access to the tree.")
      fi
      [[ "$mode" != "native" ]] \
        || errors+=("opencode slot '$id' cannot use structured_output 'native': opencode 1.18.8 has no --output-schema")

      # A misspelt variant is a SILENT failure, unlike a misspelt model: opencode
      # forwards an unknown value without complaint and the provider ignores it, so
      # the slot quietly runs at the model's default effort while the roster claims
      # otherwise -- and a flagship slot bills as if you had bought high effort.
      #
      # Checked against the universal effort vocabulary, NOT a per-model table.
      # Which efforts a given model accepts is provider metadata that changes with
      # every model release (v4-pro takes low|medium|high, v4-flash high|max), so
      # encoding it here would reject valid rosters the day a new tier ships. This
      # catches the typo, not the mismatch; the per-model constraints are documented
      # on the `variant` property in rosters/roster.schema.json.
      local slot_variant
      slot_variant="$(printf '%s' "$slot" | jq -r '.variant // ""')"
      if [[ -n "$slot_variant" ]]; then
        case "$slot_variant" in
          none | minimal | low | medium | high | xhigh | max) ;;
          *) errors+=("opencode slot '$id' sets variant '$slot_variant', which is not a recognised reasoning effort (none|minimal|low|medium|high|xhigh|max). opencode forwards an unknown variant without error and the provider ignores it, so this would silently run at the model's default effort.") ;;
        esac
      fi
    fi
    if [[ "$harness" == "codex" ]]; then
      # D3: ~/.codex/config.toml sets model_reasoning_effort globally (xhigh on
      # this machine). Unpinned, debate cost and latency are hostage to whatever
      # the user last put in a global config file.
      [[ -n "$(printf '%s' "$slot" | jq -r '.reasoning_effort // ""')" ]] \
        || errors+=("codex slot '$id' must pin reasoning_effort, else it inherits the global model_reasoning_effort from ~/.codex/config.toml")
    fi
  done

  # The judge is the one slot whose output drives control flow: `recommendation`
  # decides whether a replay round happens. A best-effort text extraction miss
  # there does not degrade quality, it silently changes what the program does.
  if [[ -n "$JUDGE_ID" && "$NO_JUDGE" -eq 0 ]]; then
    local judge_mode
    judge_mode="$(slot_field "$JUDGE_ID" '.structured_output')"
    if [[ "$judge_mode" != "native" ]]; then
      if [[ "$ALLOW_UNSTRUCTURED_JUDGE" -eq 1 ]]; then
        warn "judge slot '$JUDGE_ID' has structured_output '$judge_mode' and --allow-unstructured-judge was passed; a parse miss will silently skip the replay round"
      else
        errors+=("judge slot '$JUDGE_ID' must use structured_output 'native' (its recommendation enum drives control flow); override with --allow-unstructured-judge")
      fi
    fi
  fi
  if [[ -z "$JUDGE_ID" && "$NO_JUDGE" -eq 0 ]]; then
    errors+=("roster has no judge slot; pass --no-judge to run without one")
  fi

  if [[ "${#errors[@]}" -gt 0 ]]; then
    local err
    for err in "${errors[@]}"; do
      printf '%sroster:%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$err" >&2
    done
    refuse "roster validation failed (${#errors[@]} problem(s)) -- source $ROSTER_SOURCE"
  fi

  warn_judge_independence
}

# Upstream's judge is not actually independent: judge=claude with the same
# default model as agent1. Making the judge a roster slot exposes the problem
# instead of hiding it -- but a roster CAN still put the same model on both
# sides, and when it does we say so rather than letting the judge prompt's
# "You did not participate in the debate" go unqualified.
warn_judge_independence() {
  [[ -n "$JUDGE_ID" && "$NO_JUDGE" -eq 0 ]] || return 0
  local judge_pair
  judge_pair="$(slot_field "$JUDGE_ID" '"\(.harness)/\(.model)"')"
  local id
  for id in "${DEBATER_IDS[@]}"; do
    local pair
    pair="$(slot_field "$id" '"\(.harness)/\(.model)"')"
    if [[ "$pair" == "$judge_pair" ]]; then
      warn "judge slot '$JUDGE_ID' runs the same $judge_pair as debater '$id': the judge is session-independent (a fresh process, no shared context) but NOT model-independent. Use the 'trio' roster for a judge on a different model."
      return 0
    fi
  done
}

print_roster() {
  step "Roster: $(roster_get '.id // "?"') (source: $ROSTER_SOURCE)"
  info "$(roster_get '.description // ""')"
  local slots
  slots="$(roster_slots_json)"
  printf '%s' "$slots" | jq -r '
    .[] | "  \(.role | .[0:1] | ascii_upcase)\(.role[1:])\t\(.id)\t\(.label)\t\(.harness)/\(.model)\t\(.structured_output)\t(model from \(.model_source // "roster"))"
  ' | column -t -s $'\t' 2>/dev/null || printf '%s' "$slots" | jq -r '.[] | "  \(.role) \(.id) \(.harness)/\(.model)"'
  info "Rounds: $ROUNDS + up to $MAX_EXTRA_ROUNDS judge replay"
  info "Contract: $CONTRACT_ID ($CONTRACT_NOUN) from $CONTRACT_SOURCE"
  # Worst case means every judge replay is spent. A replay runs a FULL debate
  # round (N debater dispatches) and is then judged again, so both terms grow:
  #   debaters: N * (1 + rounds + max_extra)   round 0, each round, each replay
  #   judge:    1 + max_extra                  one attempt per verdict
  #   synthesis: 1
  # The earlier formula counted only `rounds + max_extra` judge calls and no
  # replay debater dispatches, so it understated the worst case (13 vs 15 for
  # trio-debate at -r 2).
  local dispatches
  dispatches="$((${#DEBATER_IDS[@]} * (1 + ROUNDS + MAX_EXTRA_ROUNDS) + MAX_EXTRA_ROUNDS + 2))"
  info "Worst-case dispatches: $dispatches (nominal without a judge replay: $((${#DEBATER_IDS[@]} * (1 + ROUNDS) + 2)))"
}
