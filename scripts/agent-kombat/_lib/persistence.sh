# shellcheck shell=bash
# agent-kombat -- config.json state and round manifest publication.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: none
# Reads globals owned elsewhere: REPO_ROOT (safety.sh, written only by
#   detect_repo_root there -- read only here by write_config), ROSTER_JSON
#   (entry file, empty default -- written by load_roster and by
#   apply_model_overrides in roster.sh, and again by load_run_config in
#   runmodes.sh on --resume, so no single owner; read only here by
#   write_config), ROSTER_SOURCE (entry file, empty default -- written by
#   load_roster in roster.sh and again by load_run_config in runmodes.sh on
#   --resume, so no single owner; read only here by write_config),
#   DEBATER_IDS (roster.sh,
#   written only by index_roster_slots there -- read here by
#   write_round_manifest and publish_round), ROUNDS, MAX_EXTRA_ROUNDS (entry
#   file, written by parse_args and by load_run_config in runmodes.sh on
#   --resume -- both are also conditionally written by load_roster's
#   roster-default fallback in roster.sh, so neither has a single owner;
#   both read only here by write_config), NO_JUDGE (entry
#   file, written by parse_args and conditionally by load_run_config in
#   runmodes.sh -- also read by validate_roster and warn_judge_independence
#   in roster.sh, and by run_judge_loop in orchestration.sh; read only here
#   by write_config), VERSION, UPSTREAM_SHA
#   (entry file, top-level constants that are never reassigned -- also read
#   by parse_args's --version handler there; read only here by
#   write_config), DEBUG_AGENT_CALLS (entry file, written only by parse_args
#   -- also read by adapter_claude in adapters.sh; read only here by
#   write_config), HEARTBEAT_INTERVAL, DEFAULT_IDLE_TIMEOUT (entry file,
#   written only by parse_args -- HEARTBEAT_INTERVAL is also read by par_run
#   and DEFAULT_IDLE_TIMEOUT by slot_idle_timeout, both in _lib/dispatch.sh;
#   both read only here by write_config),
#   MAX_READS_PER_TURN (entry file, top-level constant, never reassigned --
#   also read by warn_read_heavy_turn in adapters.sh; read only here by
#   write_config), CONTRACT_ID, CONTRACT_NOUN, CONTRACT_SOURCE,
#   CONTRACT_OUTPUT_FIELD, CONTRACT_REVISED_FIELD, CONTRACT_FINAL_FILENAME,
#   CONTRACT_FINAL_LABEL, CONTRACT_CONTEXT_MODE, CONTRACT_INITIAL_TASK,
#   CONTRACT_DEBATE_TASK, CONTRACT_SYNTHESIS_TASK, CONTRACT_ROUND0_NOTE,
#   CONTRACT_SYNTHESIS_NOTE (contracts.sh -- load_contract there writes all
#   thirteen from the contract JSON; CONTRACT_CONTEXT_MODE is then
#   conditionally rewritten by normalise_context_mode's fallback branch,
#   also there -- both read and write it, per contracts.sh's own header.
#   load_run_config in _lib/runmodes.sh is a second writer of all thirteen
#   on the --resume path -- contracts.sh's header calls this deliberate
#   coupling, not an ownership gap. CONTRACT_ID and CONTRACT_NOUN are read by
#   both
#   write_config and write_round_manifest here; the rest are read only by
#   write_config here)

# Guard against double-sourcing.
[ -n "${_AK_PERSISTENCE_SOURCED:-}" ] && return 0
_AK_PERSISTENCE_SOURCED=1

# ---------------------------------------------------------------------------
# config.json
# ---------------------------------------------------------------------------

write_config() {
  local target="$1"
  local origin_cwd="$2"
  local phase="$3"
  local status="$4"
  local config_file="${5:-$target/config.json}"

  local harnesses='{}'
  local harness
  while IFS= read -r harness; do
    [[ -n "$harness" ]] || continue
    harnesses="$(printf '%s' "$harnesses" | jq -c \
      --arg name "$harness" \
      --arg path "$(command -v "$harness" 2>/dev/null || printf '')" \
      --arg version "$(tool_version "$harness")" \
      '. + {($name): {path: $path, version: $version}}')"
  done < <(roster_harnesses)
  harnesses="$(printf '%s' "$harnesses" | jq -c \
    --arg path "$(command -v jq)" --arg version "$(tool_version jq)" \
    '. + {jq: {path: $path, version: $version}}')"

  jq -n \
    --arg origin_cwd "$origin_cwd" \
    --arg repo_root "$REPO_ROOT" \
    --arg workdir "$(abs_path "$target")" \
    --arg phase "$phase" \
    --arg status "$status" \
    --arg version "$VERSION" \
    --arg upstream_sha "$UPSTREAM_SHA" \
    --arg roster_source "$ROSTER_SOURCE" \
    --arg git_head "$(cd "$REPO_ROOT" && git rev-parse HEAD 2>/dev/null || printf 'unknown')" \
    --argjson roster "$ROSTER_JSON" \
    --argjson slots "$(roster_slots_json)" \
    --argjson harnesses "$harnesses" \
    --argjson rounds "$ROUNDS" \
    --argjson max_extra "$MAX_EXTRA_ROUNDS" \
    --argjson judge_enabled "$([[ "$NO_JUDGE" -eq 1 ]] && printf false || printf true)" \
    --argjson debug_agent_calls "$([[ "$DEBUG_AGENT_CALLS" -eq 1 ]] && printf true || printf false)" \
    --argjson heartbeat_interval "$HEARTBEAT_INTERVAL" \
    --argjson default_idle_timeout "$DEFAULT_IDLE_TIMEOUT" \
    --argjson max_reads_per_turn "$MAX_READS_PER_TURN" \
    --arg contract_id "$CONTRACT_ID" \
    --arg contract_noun "$CONTRACT_NOUN" \
    --arg contract_source "$CONTRACT_SOURCE" \
    --arg output_field "$CONTRACT_OUTPUT_FIELD" \
    --arg revised_field "$CONTRACT_REVISED_FIELD" \
    --arg final_filename "$CONTRACT_FINAL_FILENAME" \
    --arg final_label "$CONTRACT_FINAL_LABEL" \
    --arg context_mode "$CONTRACT_CONTEXT_MODE" \
    --arg initial_task "$CONTRACT_INITIAL_TASK" \
    --arg debate_task "$CONTRACT_DEBATE_TASK" \
    --arg synthesis_task "$CONTRACT_SYNTHESIS_TASK" \
    --arg round0_note "$CONTRACT_ROUND0_NOTE" \
    --arg synthesis_note "$CONTRACT_SYNTHESIS_NOTE" \
    '{
      version: $version,
      upstream_sha: $upstream_sha,
      origin_cwd: $origin_cwd,
      repo_root: $repo_root,
      git_head: $git_head,
      workdir: $workdir,
      phase: $phase,
      status: $status,
      roster: ($roster + {source: $roster_source}),
      slots: ($slots | map({key: .id, value: (. + {session_id: null})}) | from_entries),
      slot_order: [$slots[].id],
      debater_ids: [$slots[] | select(.role == "debater") | .id],
      judge_id: ([$slots[] | select(.role == "judge") | .id] | first),
      synthesizer_id: ([$slots[] | select(.role == "synthesizer") | .id] | first),
      contract: {
        id: $contract_id,
        noun: $contract_noun,
        source: $contract_source,
        output_field: $output_field,
        revised_field: $revised_field,
        final_filename: $final_filename,
        final_label: $final_label,
        context_mode: $context_mode,
        initial_task: $initial_task,
        debate_task: $debate_task,
        synthesis_task: $synthesis_task,
        round0_note: $round0_note,
        synthesis_note: $synthesis_note
      },
      harnesses: $harnesses,
      rounds_planned: $rounds,
      max_extra_rounds: $max_extra,
      extra_rounds_used: 0,
      judge_enabled: $judge_enabled,
      runtime: {
        debug_agent_calls: $debug_agent_calls,
        heartbeat_interval_seconds: $heartbeat_interval,
        default_idle_timeout_seconds: $default_idle_timeout,
        max_reads_per_turn: $max_reads_per_turn
      },
      published_round: -1,
      current_round: 0,
      last_successful_artifact: null
    }' | write_atomic "$config_file"
}

update_config() {
  local target="$1"
  shift
  local tmp
  tmp="$(mktemp "$target/config.json.tmp.XXXXXX")"
  jq "$@" "$target/config.json" >"$tmp"
  mv "$tmp" "$target/config.json"
}

config_get() {
  local target="$1"
  jq -r "$2" "$target/config.json"
}

# ---------------------------------------------------------------------------
# Manifests and publication
# ---------------------------------------------------------------------------
#
# Kept from upstream: the manifest plus its sha256 receipts is the determinism
# proof -- evidence that round N's inputs were exactly round N-1's published
# artifacts. With N debaters that matters more, not less, because there are more
# ways for a stale input to slip in unnoticed.

write_round_manifest() {
  local target="$1"
  local round="$2"
  local kind="$3"
  local manifest="$target/rounds/r${round}.manifest.json"
  local slots='{}'
  local id

  for id in "${DEBATER_IDS[@]}"; do
    local prefix="$target/rounds/r${round}-${id}"
    local rc="unknown"
    [[ ! -f "${prefix}.rc" ]] || rc="$(cat "${prefix}.rc")"
    slots="$(printf '%s' "$slots" | jq -c \
      --arg id "$id" \
      --arg label "$(slot_field "$id" '.label')" \
      --arg harness "$(slot_field "$id" '.harness')" \
      --arg model "$(slot_field "$id" '.model')" \
      --arg prompt_path "rounds/r${round}-${id}.prompt.txt" \
      --arg prompt_sha "$(sha256_file "${prefix}.prompt.txt")" \
      --arg output_path "rounds/r${round}-${id}.md" \
      --arg output_sha "$(sha256_file "${prefix}.md")" \
      --arg turn_path "rounds/r${round}-${id}.turn.json" \
      --arg raw_path "rounds/r${round}-${id}.raw" \
      --arg session_id "$(config_get "$target" ".slots[\"$id\"].session_id // \"\"")" \
      --arg rc "$rc" \
      '. + {($id): {
        label: $label,
        harness: $harness,
        model: $model,
        prompt_path: $prompt_path,
        prompt_sha256: $prompt_sha,
        output_path: $output_path,
        output_sha256: $output_sha,
        turn_path: $turn_path,
        raw_path: $raw_path,
        session_id: $session_id,
        exit_code: ($rc | tonumber? // -1),
        parse_status: "ok"
      }}')"
  done

  local frozen='{}'
  if [[ "$kind" == "debate" ]]; then
    for id in "${DEBATER_IDS[@]}"; do
      frozen="$(printf '%s' "$frozen" | jq -c \
        --arg id "$id" \
        --arg path "rounds/r${round}-input-${id}.md" \
        --arg sha "$(sha256_file "$target/rounds/r${round}-input-${id}.md")" \
        '. + {($id): {path: $path, sha256: $sha}}')"
    done
  else
    frozen="$(jq -n \
      --arg req "requirement.txt" \
      --arg req_sha "$(sha256_file "$target/requirement.txt")" \
      --arg ctx "rounds/r0-shared-context.md" \
      --arg ctx_sha "$(sha256_file "$target/rounds/r0-shared-context.md")" \
      '{requirement: {path: $req, sha256: $req_sha}, shared_context: {path: $ctx, sha256: $ctx_sha}}')"
  fi

  jq -n \
    --arg round "r${round}" \
    --arg kind "$kind" \
    --arg cwd "$(config_get "$target" '.origin_cwd')" \
    --arg contract_id "$CONTRACT_ID" \
    --arg contract_noun "$CONTRACT_NOUN" \
    --argjson slots "$slots" \
    --argjson frozen "$frozen" \
    --arg objections "rounds/r${round}-objections.json" \
    '{
      round: $round,
      kind: $kind,
      contract: {id: $contract_id, noun: $contract_noun},
      origin_cwd: $cwd,
      frozen_inputs: $frozen,
      slots: $slots,
      objections_path: $objections,
      published: true
    }' | write_atomic "$manifest"
}

publish_round() {
  local target="$1"
  local round="$2"
  local id
  for id in "${DEBATER_IDS[@]}"; do
    cp "$target/rounds/r${round}-${id}.md" "$target/plan-${id}.md"
  done
}

# Resume is per-participant within a round, not per-round: a slot that already
# has a validated turn is not re-dispatched and not paid for twice. Strictly
# better than upstream, which discards a partial round wholesale.
slot_turn_valid() {
  local target="$1"
  local round="$2"
  local id="$3"
  local validator="$4"
  local turn="$target/rounds/r${round}-${id}.turn.json"
  [[ -s "$turn" ]] || return 1
  "$validator" "$turn" 2>/dev/null
}

# Turn the validated structured payload into the markdown a competitor reads
# next round.
extract_plan_markdown() {
  local target="$1"
  local round="$2"
  local id="$3"
  local field="$4"
  jq -er --arg field "$field" '.[$field] | select(type == "string" and length > 0)' \
    "$target/rounds/r${round}-${id}.turn.json" >"$target/rounds/r${round}-${id}.md"
}
