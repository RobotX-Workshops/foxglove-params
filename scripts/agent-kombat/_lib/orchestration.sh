# shellcheck shell=bash
# agent-kombat -- Round 0, debate rounds, judge, synthesis and the final report.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: none
# Reads globals owned elsewhere: DEBATER_IDS, JUDGE_ID, SYNTH_ID (roster.sh,
#   index_roster_slots -- DEBATER_IDS read by run_round0, run_debate_round
#   and print_final_report here; JUDGE_ID read by run_judge_attempt and
#   run_synthesis here; SYNTH_ID read by run_synthesis here, via the
#   ${SYNTH_ID:-$JUDGE_ID} fallback), CONTRACT_ID, CONTRACT_NOUN,
#   CONTRACT_OUTPUT_FIELD, CONTRACT_REVISED_FIELD, CONTRACT_FINAL_FILENAME,
#   CONTRACT_FINAL_LABEL (contracts.sh, load_contract -- CONTRACT_ID read by
#   run_round0; CONTRACT_NOUN read by run_round0, run_judge_loop and
#   print_final_report; CONTRACT_OUTPUT_FIELD read by run_round0;
#   CONTRACT_REVISED_FIELD read by run_debate_round; CONTRACT_FINAL_FILENAME
#   and CONTRACT_FINAL_LABEL read by run_synthesis and print_final_report),
#   ROUNDS, NO_JUDGE, MAX_EXTRA_ROUNDS (entry file, parse_args -- ROUNDS read
#   by run_debate_loop; NO_JUDGE and MAX_EXTRA_ROUNDS read by run_judge_loop;
#   all three also written a second time by load_run_config in
#   _lib/runmodes.sh on the --resume path; ROUNDS and MAX_EXTRA_ROUNDS each
#   have a third, conditional writer too -- load_roster's roster-default
#   fallback in roster.sh, when the CLI left them empty), COLOR_YELLOW,
#   COLOR_RESET (common.sh, init_color -- read only by print_final_report
#   here, directly in its unresolved/suspicious-issue printf calls, not via
#   warn/info)

# Guard against double-sourcing.
[ -n "${_AK_ORCHESTRATION_SOURCED:-}" ] && return 0
_AK_ORCHESTRATION_SOURCED=1

# ---------------------------------------------------------------------------
# Round 0
# ---------------------------------------------------------------------------

run_round0() {
  local target="$1"
  local schema_file="$target/schemas/round0.schema.json"
  local id

  step "Round 0: ${#DEBATER_IDS[@]} independent ${CONTRACT_NOUN}s (blind)"
  update_config "$target" '.phase = "round" | .status = "running" | .current_round = 0'
  log_event "$target" "round.started" "$(jq -n --arg round r0 --argjson participants "${#DEBATER_IDS[@]}" \
    '{round: $round, participants: $participants}')"

  prepare_shared_context "$target"

  # Round-0 blindness is structural, not merely prompted: no competitor artifact
  # exists yet, so a participant could not read one even if it tried.
  par_reset
  for id in "${DEBATER_IDS[@]}"; do
    local prefix="$target/rounds/r0-${id}"
    if slot_turn_valid "$target" 0 "$id" "validate_round0_response"; then
      info "round 0: slot '$id' already has a valid turn; not re-dispatching"
      continue
    fi
    build_round0_prompt "$id" "$target" "$schema_file" >"${prefix}.prompt.txt"
    par_add "$id" "new" "${prefix}.prompt.txt" "$schema_file" "$prefix" \
      "${prefix}.events.jsonl" "$(slot_idle_timeout "$id")" "" "validate_round0_response"
  done

  local failures=0
  par_run "$target" "round 0" || failures=$?
  collect_session_ids "$target"
  merge_round_events "$target" 0
  assert_tree_untouched "$target" "round 0"

  [[ "$failures" -eq 0 ]] \
    || die "round 0: $failures of ${#DEBATER_IDS[@]} participants failed. Fix the cause and re-run with --resume $target"

  for id in "${DEBATER_IDS[@]}"; do
    validate_round0_response "$target/rounds/r0-${id}.turn.json" \
      || die "round 0: slot '$id' produced no valid $CONTRACT_OUTPUT_FIELD (see rounds/r0-${id}.raw)"
    extract_plan_markdown "$target" 0 "$id" "$CONTRACT_OUTPUT_FIELD"
  done

  publish_round "$target" 0
  write_round_manifest "$target" 0 "independent_$CONTRACT_ID"
  update_config "$target" '.published_round = 0 | .current_round = 1 | .last_successful_artifact = "rounds/r0.manifest.json"'
  log_event "$target" "round.published" "$(jq -n --arg round r0 --argjson published_round 0 \
    '{round: $round, published_round: $published_round}')"
  ok "Round 0 published"
}

# ---------------------------------------------------------------------------
# Debate rounds
# ---------------------------------------------------------------------------

run_debate_round() {
  local target="$1"
  local round="$2"
  local focus_file="${3:-}"
  local schema_file="$target/schemas/debater.schema.json"
  local id

  # Freeze this round's inputs before anything is dispatched. The frozen copies
  # are what the manifest hashes, so the record is of what was actually sent.
  for id in "${DEBATER_IDS[@]}"; do
    cp "$target/plan-${id}.md" "$target/rounds/r${round}-input-${id}.md"
  done

  step "Round $round: debate (${#DEBATER_IDS[@]} participants, full mesh)"
  update_config "$target" --argjson round "$round" \
    '.phase = "round" | .status = "running" | .current_round = $round'
  log_event "$target" "round.started" "$(jq -n --arg round "r${round}" \
    --argjson participants "${#DEBATER_IDS[@]}" \
    --argjson replay "$([[ -n "$focus_file" ]] && printf true || printf false)" \
    '{round: $round, participants: $participants, judge_replay: $replay}')"

  par_reset
  for id in "${DEBATER_IDS[@]}"; do
    local prefix="$target/rounds/r${round}-${id}"
    if slot_turn_valid "$target" "$round" "$id" "validate_debater_response"; then
      info "round $round: slot '$id' already has a valid turn; not re-dispatching"
      continue
    fi
    build_debate_prompt "$id" "$target" "$round" "$schema_file" "$focus_file" >"${prefix}.prompt.txt"
    local session
    session="$(config_get "$target" ".slots[\"$id\"].session_id // \"\"")"
    local mode="resume"
    # A slot with no session (e.g. one whose round-0 session was lost) starts a
    # fresh one rather than dying: its prompt already carries its own plan and
    # every competitor's, so it is self-contained.
    if [[ -z "$session" || "$session" == "null" ]]; then
      mode="new"
      warn "slot '$id' has no session id; starting a fresh session for round $round"
    fi
    par_add "$id" "$mode" "${prefix}.prompt.txt" "$schema_file" "$prefix" \
      "${prefix}.events.jsonl" "$(slot_idle_timeout "$id")" "$session" "validate_debater_response"
  done

  local failures=0
  par_run "$target" "round $round" || failures=$?
  collect_session_ids "$target"
  merge_round_events "$target" "$round"
  assert_tree_untouched "$target" "round $round"

  [[ "$failures" -eq 0 ]] \
    || die "round $round: $failures of ${#DEBATER_IDS[@]} participants failed. Re-run with --resume $target to retry only the failed slots"

  for id in "${DEBATER_IDS[@]}"; do
    validate_debater_response "$target/rounds/r${round}-${id}.turn.json" \
      || die "round $round: slot '$id' failed debater schema validation (see rounds/r${round}-${id}.turn.json)"
    extract_plan_markdown "$target" "$round" "$id" "$CONTRACT_REVISED_FIELD"
  done

  write_objections_ledger "$target" "$round"
  publish_round "$target" "$round"
  write_round_manifest "$target" "$round" "debate"
  update_config "$target" --argjson round "$round" --arg artifact "rounds/r${round}.manifest.json" \
    '.published_round = $round | .current_round = ($round + 1) | .last_successful_artifact = $artifact'
  log_event "$target" "round.published" "$(jq -n --arg round "r${round}" --argjson published_round "$round" \
    '{round: $round, published_round: $published_round}')"
  ok "Round $round published"
}

run_debate_loop() {
  local target="$1"
  [[ "$ROUNDS" -gt 0 ]] || return 0
  local start_round
  start_round="$(($(config_get "$target" '.published_round') + 1))"
  [[ "$start_round" -ge 1 ]] || start_round=1
  local round
  for ((round = start_round; round <= ROUNDS; round++)); do
    run_debate_round "$target" "$round"
  done
}

# ---------------------------------------------------------------------------
# Judge
# ---------------------------------------------------------------------------

run_judge_attempt() {
  local target="$1"
  local attempt="$2"
  local schema_file="$target/schemas/judge.schema.json"
  local prefix="$target/rounds/judge-${attempt}"

  build_round_summary_json "$target" >"${prefix}-round-summary.json"
  build_objections_json "$target" >"${prefix}-objections.json"
  build_judge_prompt "$target" "${prefix}-round-summary.json" "${prefix}-objections.json" "$schema_file" \
    >"${prefix}.prompt.txt"

  update_config "$target" '.phase = "judge"'
  log_event "$target" "judge.call.started" "$(jq -n --argjson attempt "$attempt" \
    --arg slot "$JUDGE_ID" '{attempt: $attempt, slot: $slot}')"

  par_reset
  # A fresh session every attempt: the judge must grade the published artifacts,
  # not accumulate its own prior opinions across replays.
  par_add "$JUDGE_ID" "new" "${prefix}.prompt.txt" "$schema_file" "$prefix" \
    "${prefix}.events.jsonl" "$(slot_idle_timeout "$JUDGE_ID")" "" "validate_judge_verdict"

  local failures=0
  par_run "$target" "judge attempt $attempt" || failures=$?
  # Record the session for the audit trail even though the judge never resumes
  # one -- knowing which session produced a verdict is what makes the verdict
  # traceable back to a transcript.
  collect_session_ids "$target"
  # The judge's own events go straight to the main log: there is only one of it,
  # so there is no ordering ambiguity to resolve.
  cat "${prefix}.events.jsonl" >>"$target/events.jsonl" 2>/dev/null || true
  assert_tree_untouched "$target" "judge attempt $attempt"

  [[ "$failures" -eq 0 ]] || die "judge attempt $attempt failed"
  validate_judge_verdict "${prefix}.turn.json" \
    || die "judge attempt $attempt failed verdict validation (see ${prefix}.turn.json)"

  cp "${prefix}.turn.json" "$target/judge-verdict.json"
  update_config "$target" --arg artifact "judge-verdict.json" '.last_successful_artifact = $artifact'
  log_event "$target" "judge.call.completed" "$(jq -n --argjson attempt "$attempt" \
    --arg recommendation "$(jq -r '.recommendation' "$target/judge-verdict.json")" \
    --argjson converged "$(jq -r '.converged' "$target/judge-verdict.json")" \
    '{attempt: $attempt, recommendation: $recommendation, converged: $converged}')"
}

run_judge_loop() {
  local target="$1"
  [[ "$NO_JUDGE" -eq 0 ]] || {
    info "judge disabled (--no-judge); the final $CONTRACT_NOUN will be synthesized without independent review"
    return 0
  }
  local status
  status="$(config_get "$target" '.status')"
  [[ "$status" != "done" ]] || return 0

  local attempt=1
  local prev_objections=""
  while :; do
    step "Judge attempt $attempt"
    run_judge_attempt "$target" "$attempt"

    local recommendation extra_used
    recommendation="$(jq -r '.recommendation' "$target/judge-verdict.json")"
    extra_used="$(config_get "$target" '.extra_rounds_used')"

    if [[ "$recommendation" != "another_round" ]]; then
      update_config "$target" '.phase = "judge" | .status = "judged"'
      break
    fi
    if [[ "$extra_used" -ge "$MAX_EXTRA_ROUNDS" ]]; then
      warn "judge asked for another round but the replay budget ($MAX_EXTRA_ROUNDS) is spent; synthesizing with unresolved issues outstanding"
      log_event "$target" "judge.replay.budget_exhausted" "$(jq -n --argjson used "$extra_used" \
        --argjson budget "$MAX_EXTRA_ROUNDS" '{extra_rounds_used: $used, max_extra_rounds: $budget}')"
      update_config "$target" '.phase = "judge" | .status = "judged"'
      break
    fi

    # Stable-disagreement detector, lifted from this repo's local-pr-review loop
    # (step 4 there). Upstream only ever stops on the round cap or the judge's
    # say-so, so it will happily pay for a replay that reproduces the previous
    # round's objections verbatim.
    local objections
    objections="$(jq -Sc '.unresolved_issues' "$target/judge-verdict.json")"
    if [[ -n "$prev_objections" && "$objections" == "$prev_objections" ]]; then
      warn "judge returned byte-identical unresolved issues two attempts running: stable disagreement, not progress. Stopping the replay loop."
      log_event "$target" "judge.stable_disagreement" "$(jq -n --argjson attempt "$attempt" \
        '{attempt: $attempt}')"
      update_config "$target" '.phase = "judge" | .status = "judged"'
      break
    fi
    prev_objections="$objections"

    local next_round focus_file
    next_round="$(($(config_get "$target" '.published_round') + 1))"
    focus_file="$target/rounds/r${next_round}-judge-focus.txt"
    jq -r '.focus_for_next_round // "Focus on the unresolved issues the judge listed."' \
      "$target/judge-verdict.json" >"$focus_file"
    update_config "$target" '.extra_rounds_used = (.extra_rounds_used + 1)'
    log_event "$target" "judge.replay.requested" "$(jq -n --argjson next_round "$next_round" \
      --arg focus_path "rounds/r${next_round}-judge-focus.txt" \
      '{next_round: $next_round, focus_path: $focus_path}')"
    run_debate_round "$target" "$next_round" "$focus_file"
    attempt="$((attempt + 1))"
  done
  ok "Judge verdict written: $target/judge-verdict.json"
}

# ---------------------------------------------------------------------------
# Synthesis
# ---------------------------------------------------------------------------

run_synthesis() {
  local target="$1"
  local synth_id="${SYNTH_ID:-$JUDGE_ID}"
  [[ -n "$synth_id" ]] || die "no synthesizer or judge slot to synthesize with"
  local prefix="$target/rounds/synthesis"

  step "Synthesis via slot '$synth_id'"
  build_synthesis_prompt "$target" >"${prefix}.prompt.txt"
  update_config "$target" --arg slot "$synth_id" \
    '.phase = "synthesis" | .status = "running" | .synthesizer_used = $slot'
  log_event "$target" "synthesis.call.started" "$(jq -n --arg slot "$synth_id" '{slot: $slot}')"

  # An empty schema file is the signal for "markdown, not JSON" -- synthesis
  # returns the deliverable itself.
  : >"${prefix}.noschema.json"

  par_reset
  par_add "$synth_id" "new" "${prefix}.prompt.txt" "${prefix}.noschema.json" "$prefix" \
    "${prefix}.events.jsonl" "$(slot_idle_timeout "$synth_id")" "" "validate_debater_response"

  local failures=0
  par_run "$target" "synthesis" || failures=$?
  collect_session_ids "$target"
  cat "${prefix}.events.jsonl" >>"$target/events.jsonl" 2>/dev/null || true
  assert_tree_untouched "$target" "synthesis"

  [[ "$failures" -eq 0 ]] || die "synthesis failed"
  [[ -s "${prefix}.md" ]] || die "synthesis produced no markdown (see ${prefix}.raw)"

  cp "${prefix}.md" "$target/$CONTRACT_FINAL_FILENAME"
  update_config "$target" --arg artifact "$CONTRACT_FINAL_FILENAME" \
    '.phase = "done" | .status = "done" | .last_successful_artifact = $artifact'
  log_event "$target" "synthesis.call.completed" "$(jq -n --arg artifact "$CONTRACT_FINAL_FILENAME" \
    '{artifact: $artifact}')"
  ok "$CONTRACT_FINAL_LABEL: $target/$CONTRACT_FINAL_FILENAME"
}

# ---------------------------------------------------------------------------
# Final report
# ---------------------------------------------------------------------------

print_final_report() {
  local target="$1"
  printf '\n'
  step "Debate complete"
  printf 'Run dir:      %s\n' "$target"
  printf '%s:  %s\n' "$CONTRACT_FINAL_LABEL" "$target/$CONTRACT_FINAL_FILENAME"
  local id
  for id in "${DEBATER_IDS[@]}"; do
    printf 'Participant:  %-12s %-28s %s\n' \
      "$id" "$(slot_field "$id" '"\(.harness)/\(.model)"')" "$target/plan-${id}.md"
  done
  if [[ -f "$target/judge-verdict.json" ]]; then
    printf 'Judge:        converged=%s recommendation=%s\n' \
      "$(jq -r '.converged' "$target/judge-verdict.json")" \
      "$(jq -r '.recommendation' "$target/judge-verdict.json")"
    local unresolved
    unresolved="$(jq -r '.unresolved_issues | length' "$target/judge-verdict.json")"
    if [[ "$unresolved" -gt 0 ]]; then
      # The part people skip. Say it loudly.
      printf '\n%sUnresolved issues the judge flagged (%s) -- read these before trusting the plan:%s\n' \
        "$COLOR_YELLOW" "$unresolved" "$COLOR_RESET"
      jq -r '.unresolved_issues[] | "  - " + .' "$target/judge-verdict.json"
    fi
    local suspicious
    suspicious="$(jq -r '.agreements_lacking_justification | length' "$target/judge-verdict.json")"
    if [[ "$suspicious" -gt 0 ]]; then
      printf '\n%sAgreements the judge could not see justified (%s):%s\n' \
        "$COLOR_YELLOW" "$suspicious" "$COLOR_RESET"
      jq -r '.agreements_lacking_justification[] | "  - " + .' "$target/judge-verdict.json"
    fi
  else
    warn "no judge verdict: this plan had no independent review"
  fi
  local dispatches
  dispatches="$(grep -c '"event":"agent.call.completed"' "$target/events.jsonl" 2>/dev/null || printf 0)"
  printf '\nDispatches completed: %s\n' "$dispatches"
  printf 'Events:       %s\n' "$target/events.jsonl"
  printf '\nNext: ground the final %s against the real repo before acting on it.\n' "$CONTRACT_NOUN"
}

