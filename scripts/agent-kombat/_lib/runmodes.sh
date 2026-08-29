# shellcheck shell=bash
# agent-kombat -- Debate skeleton, --show, --resume and --dry-run.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: none
# Reads globals owned elsewhere: DEBATER_IDS (roster.sh, index_roster_slots
#   -- read by create_debate_skeleton, reconstruct_progress, run_dry and
#   check_round0_prompt_parity), ROSTER_NAME, ROSTER_FILE (entry file,
#   parse_args -- read only by reconstruct_progress here, to warn that they
#   are ignored on resume), ROUNDS, REQUIREMENT (entry file, parse_args and
#   load_requirement_file/expand_prompt_file_refs -- ROUNDS read by
#   create_debate_skeleton (ROUNDS also has a third, conditional writer:
#   load_roster's roster-default fallback in roster.sh, when the CLI left it
#   empty); REQUIREMENT read by create_debate_skeleton and run_dry; both are
#   also RE-WRITTEN here by load_run_config on the --resume path, restoring
#   the values the run was started with rather than the current CLI
#   defaults), MAX_EXTRA_ROUNDS (same third, conditional writer as ROUNDS,
#   via the same load_roster fallback), NO_JUDGE (entry file,
#   parse_args -- consumed by run_judge_loop in orchestration.sh; WRITTEN
#   here, not read, by load_run_config on the --resume path),
#   CONTRACT_ID, CONTRACT_FINAL_FILENAME (contracts.sh -- CONTRACT_ID read
#   by create_debate_skeleton; CONTRACT_FINAL_FILENAME read by resume_run;
#   both are also RE-WRITTEN here by load_run_config on the --resume path,
#   along with the other eleven CONTRACT_* fields (CONTRACT_NOUN,
#   CONTRACT_SOURCE, CONTRACT_OUTPUT_FIELD, CONTRACT_REVISED_FIELD,
#   CONTRACT_FINAL_LABEL, CONTRACT_CONTEXT_MODE, CONTRACT_INITIAL_TASK,
#   CONTRACT_DEBATE_TASK, CONTRACT_SYNTHESIS_TASK, CONTRACT_ROUND0_NOTE,
#   CONTRACT_SYNTHESIS_NOTE) which load_run_config writes here but never
#   reads back -- a resumed run must reconstruct the contract it started
#   with, not the current defaults), ROSTER_JSON, ROSTER_SOURCE (roster.sh
#   -- likewise RE-WRITTEN, not read, by load_run_config here on the
#   --resume path, restoring the roster the run was started with).
#
# Duplication on file (not fixed here): check_round0_prompt_parity, here,
# hardcodes three literal sentences that must byte-match
# harness_schema_sentence's output in _lib/prompts.sh. That duplication now
# spans two files. A shared constant would be the right fix; that is a
# future commit.

# Guard against double-sourcing.
[ -n "${_AK_RUNMODES_SOURCED:-}" ] && return 0
_AK_RUNMODES_SOURCED=1

# ---------------------------------------------------------------------------
# Skeleton, show, resume
# ---------------------------------------------------------------------------

create_debate_skeleton() {
  local target="$1"
  [[ ! -e "$target" ]] || die "workdir already exists: $target"
  mkdir -p "$target/rounds" "$target/schemas"
  printf '%s\n' "$REQUIREMENT" >"$target/requirement.txt"
  : >"$target/events.jsonl"
  write_config "$target" "$PWD" "setup" "initialized"
  write_all_schemas "$target"
  snapshot_tree_baseline "$target"
  log_event "$target" "debate.initialized" "$(jq -n \
    --arg workdir "$(abs_path "$target")" \
    --argjson rounds "$ROUNDS" \
    --arg contract "$CONTRACT_ID" \
    --arg roster "$(roster_get '.id // "?"')" \
    --argjson participants "${#DEBATER_IDS[@]}" \
    '{workdir: $workdir, rounds_planned: $rounds, contract: $contract, roster: $roster, participants: $participants}')"
}

show_debate() {
  local target="$1"
  [[ -d "$target" ]] || die "show workdir does not exist: $target"
  [[ -f "$target/config.json" ]] || die "missing config.json in $target"

  jq '{
    status, phase, version, upstream_sha, git_head,
    roster: .roster.id, roster_source: .roster.source,
    contract: .contract.id,
    rounds_planned, extra_rounds_used, max_extra_rounds, judge_enabled,
    published_round, current_round, last_successful_artifact,
    slots: (.slots | map_values({label, harness, model, structured_output, session_id, model_source}))
  }' "$target/config.json"

  local noun final_filename final_label
  noun="$(jq -r '.contract.noun // "plan"' "$target/config.json")"
  final_filename="$(jq -r '.contract.final_filename // "plan-final.md"' "$target/config.json")"
  final_label="$(jq -r '.contract.final_label // "Final plan"' "$target/config.json")"

  printf '\n'
  local id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ -f "$target/plan-${id}.md" ]]; then
      printf '%s %s: %s\n' "$id" "$noun" "$target/plan-${id}.md"
    fi
  done < <(jq -r '.debater_ids[]?' "$target/config.json")

  [[ ! -f "$target/judge-verdict.json" ]] || printf 'Judge verdict: %s\n' "$target/judge-verdict.json"
  [[ ! -f "$target/$final_filename" ]] || printf '%s: %s\n' "$final_label" "$target/$final_filename"
  [[ ! -f "$target/triage.md" ]] || printf 'Grounding triage: %s\n' "$target/triage.md"
  [[ ! -f "$target/events.jsonl" ]] || printf 'Events: %s (%s lines)\n' \
    "$target/events.jsonl" "$(wc -l <"$target/events.jsonl" | tr -d ' ')"
}

# Restore the roster, contract and runtime settings a run was started with.
# Resuming with a DIFFERENT roster is refused: comparing a round-1 plan from one
# model with a round-2 plan from another is not a debate, it is a splice.
load_run_config() {
  local target="$1"
  # shellcheck disable=SC2034  # read by validate_roster/print_roster in _lib/roster.sh and write_config in _lib/persistence.sh
  ROSTER_JSON="$(jq -c '.roster | del(.source)' "$target/config.json")"
  # shellcheck disable=SC2034  # read by validate_roster/print_roster in _lib/roster.sh and write_config in _lib/persistence.sh
  ROSTER_SOURCE="$(jq -r '.roster.source // "resumed"' "$target/config.json")"
  ROUNDS="$(config_get "$target" '.rounds_planned')"
  # shellcheck disable=SC2034  # read by run_judge_loop in _lib/orchestration.sh
  MAX_EXTRA_ROUNDS="$(config_get "$target" '.max_extra_rounds')"
  # shellcheck disable=SC2034  # read by run_judge_loop in _lib/orchestration.sh
  # Restore BOTH directions. The old form could only ever set NO_JUDGE=1, so a
  # resume inherited whatever the current invocation happened to pass rather
  # than what the run was actually configured with.
  if [[ "$(config_get "$target" '.judge_enabled')" == "false" ]]; then
    NO_JUDGE=1
  else
    NO_JUDGE=0
  fi
  # Same class: without this, a run started with --allow-unstructured-judge
  # silently resumes under strict validation (or the reverse).
  if [[ "$(config_get "$target" '.allow_unstructured_judge')" == "true" ]]; then
    ALLOW_UNSTRUCTURED_JUDGE=1
  else
    ALLOW_UNSTRUCTURED_JUDGE=0
  fi
  REQUIREMENT="$(cat "$target/requirement.txt")"

  CONTRACT_ID="$(config_get "$target" '.contract.id')"
  # shellcheck disable=SC2034  # read by run_round0/run_judge_loop/print_final_report in _lib/orchestration.sh
  CONTRACT_NOUN="$(config_get "$target" '.contract.noun')"
  # shellcheck disable=SC2034  # read by print_roster in _lib/roster.sh and write_config in _lib/persistence.sh
  CONTRACT_SOURCE="$(config_get "$target" '.contract.source')"
  # shellcheck disable=SC2034  # read by run_round0 in _lib/orchestration.sh
  CONTRACT_OUTPUT_FIELD="$(config_get "$target" '.contract.output_field')"
  # shellcheck disable=SC2034  # read by run_debate_round in _lib/orchestration.sh
  CONTRACT_REVISED_FIELD="$(config_get "$target" '.contract.revised_field')"
  CONTRACT_FINAL_FILENAME="$(config_get "$target" '.contract.final_filename')"
  # shellcheck disable=SC2034  # read by run_synthesis/print_final_report in _lib/orchestration.sh
  CONTRACT_FINAL_LABEL="$(config_get "$target" '.contract.final_label')"
  # shellcheck disable=SC2034  # read by prepare_shared_context in _lib/prompts.sh
  CONTRACT_CONTEXT_MODE="$(config_get "$target" '.contract.context_mode')"
  # shellcheck disable=SC2034  # read by build_round0_prompt in _lib/prompts.sh
  CONTRACT_INITIAL_TASK="$(config_get "$target" '.contract.initial_task')"
  # shellcheck disable=SC2034  # read by build_debate_prompt in _lib/prompts.sh
  CONTRACT_DEBATE_TASK="$(config_get "$target" '.contract.debate_task')"
  # shellcheck disable=SC2034  # read by build_synthesis_prompt in _lib/prompts.sh
  CONTRACT_SYNTHESIS_TASK="$(config_get "$target" '.contract.synthesis_task')"
  # shellcheck disable=SC2034  # read by build_round0_prompt in _lib/prompts.sh
  CONTRACT_ROUND0_NOTE="$(config_get "$target" '.contract.round0_note')"
  # shellcheck disable=SC2034  # read by build_synthesis_prompt in _lib/prompts.sh
  CONTRACT_SYNTHESIS_NOTE="$(config_get "$target" '.contract.synthesis_note')"

  index_roster_slots
  validate_contract_loaded
  # Re-validate on resume. config.json is a plain file in a writable directory, so
  # a resumed roster is untrusted input: without this, hand-editing
  # .roster.debaters[].agent to "build" would dispatch a write-capable opencode
  # agent, since validate_roster is where the allowlist lives. That is the field
  # dispatch actually reads -- .slots carries only session ids. Cheap, and it also
  # catches a config written by an older driver whose rules have since tightened.
  validate_roster
}

reconstruct_progress() {
  local target="$1"
  [[ -d "$target" ]] || die "resume workdir does not exist: $target"
  [[ -f "$target/config.json" ]] || die "missing config.json in $target"
  [[ -f "$target/requirement.txt" ]] || die "missing requirement.txt in $target"
  [[ -d "$target/rounds" ]] || die "missing rounds/ in $target"

  if [[ -n "$ROSTER_NAME" || -n "$ROSTER_FILE" ]]; then
    warn "--roster/--roster-file are ignored on resume: the run's own roster is authoritative (mixing models mid-debate is not a debate)"
  fi

  # D10 pays off here: r*.manifest.json cannot collide with a per-turn file, so
  # this glob needs no defensive filtering to be correct.
  local max_round=-1
  local manifest
  for manifest in "$target"/rounds/r*.manifest.json; do
    [[ -e "$manifest" ]] || continue
    local round_num
    round_num="$(jq -r 'select(.published == true) | .round | sub("^r"; "") | tonumber' "$manifest" 2>/dev/null || true)"
    [[ -n "$round_num" ]] || continue
    [[ "$round_num" -le "$max_round" ]] || max_round="$round_num"
  done

  if [[ "$max_round" -ge 0 ]]; then
    local id
    for id in "${DEBATER_IDS[@]}"; do
      [[ -f "$target/rounds/r${max_round}-${id}.md" ]] \
        || die "resume: missing artifact for slot '$id' in the last published round r${max_round}"
      cp "$target/rounds/r${max_round}-${id}.md" "$target/plan-${id}.md"
    done
    update_config "$target" --argjson round "$max_round" \
      --arg artifact "rounds/r${max_round}.manifest.json" \
      '.published_round = $round | .current_round = ($round + 1) | .last_successful_artifact = $artifact'
  fi
  log_event "$target" "resume.reconstructed" "$(jq -n --argjson published_round "$max_round" \
    '{published_round: $published_round}')"
  info "resumed at published round r${max_round}"
}

resume_run() {
  local target="$1"
  # Containment FIRST, before anything is read from or written into the directory.
  # main() only enforced this on the fresh path, so `--resume` was an unchecked
  # write target: a crafted directory outside tmp/ would have been read for its
  # config and then written to for every subsequent round.
  enforce_workdir_location "$target"
  [[ -f "$target/config.json" ]] || die "resume workdir does not exist or has no config.json: $target"
  load_run_config "$target"
  reconstruct_progress "$target"
  preflight_tools
  # Regenerate the schemas rather than reusing the ones on disk. They are pure
  # functions of the contract fields load_run_config just restored, so for an
  # unchanged driver this rewrites them byte-identically -- but when the reason
  # the run died IS a malformed schema, reusing the stale copy makes the failure
  # unfixable in place and forces a fresh run that re-pays for round 0.
  write_all_schemas "$target"
  # Re-baseline: the tree has legitimately moved on since the original run, and
  # holding a resumed run to a stale snapshot would fail for the wrong reason.
  snapshot_tree_baseline "$target"

  if [[ "$(config_get "$target" '.status')" == "done" && -f "$target/$CONTRACT_FINAL_FILENAME" ]]; then
    ok "run already complete: $target/$CONTRACT_FINAL_FILENAME"
    return 0
  fi

  if [[ "$(config_get "$target" '.published_round')" -lt 0 ]]; then
    run_round0 "$target"
  fi
  run_debate_loop "$target"
  run_judge_loop "$target"
  run_synthesis "$target"
  print_final_report "$target"
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------
#
# Writes the whole run directory -- resolved config, all three schemas, and every
# round-0 prompt -- and calls nothing. Free, and it is what makes the round-0
# fairness property checkable: the prompts are on disk to diff.
run_dry() {
  local target="$1"
  mkdir -p "$target/rounds" "$target/schemas"
  printf '%s\n' "$REQUIREMENT" >"$target/requirement.txt"
  : >"$target/events.jsonl"
  write_config "$target" "$PWD" "dry-run" "dry-run"
  write_all_schemas "$target"
  prepare_shared_context "$target"

  local schema_file="$target/schemas/round0.schema.json"
  local id
  for id in "${DEBATER_IDS[@]}"; do
    build_round0_prompt "$id" "$target" "$schema_file" >"$target/rounds/r0-${id}.prompt.txt"
  done

  step "Dry run: no agent calls were made"
  print_roster
  printf '\nWorkdir: %s\n' "$(abs_path "$target")"
  printf 'Prompts written:\n'
  for id in "${DEBATER_IDS[@]}"; do
    printf '  %-12s %8s bytes  %s\n' "$id" \
      "$(file_size_bytes "$target/rounds/r0-${id}.prompt.txt")" \
      "rounds/r0-${id}.prompt.txt"
  done

  printf '\nCommands that would run in round 0:\n'
  for id in "${DEBATER_IDS[@]}"; do
    printf '  %s\n' "$(describe_dispatch "$id" "$schema_file")"
  done

  # Round-0 fairness: every participant must get the same prompt apart from its
  # own label. Verified here rather than asserted in prose.
  check_round0_prompt_parity "$target"
  printf '\nInspect: %s\n' "$target/config.json"
}

# A human-readable rendering of the exact argv each adapter will use. Not
# executed -- it exists so a reviewer can see the flags without reading bash.
describe_dispatch() {
  local slot_id="$1"
  local schema_file="$2"
  local harness model
  harness="$(slot_field "$slot_id" '.harness')"
  model="$(slot_field "$slot_id" '.model')"
  case "$harness" in
    claude)
      # Must mirror adapter_claude exactly: read-only allowlist, prompt on stdin.
      # A preview that shows `--tools ""` or an argv prompt teaches the two things
      # that were bugs.
      printf 'claude -p --model %s --session-id <uuid> --tools "Read,Grep,Glob" --output-format json --json-schema <%s> < rounds/r0-%s.prompt.txt' \
        "$model" "$(basename "$schema_file")" "$slot_id"
      ;;
    codex)
      printf 'codex exec --model %s -c model_reasoning_effort="%s" --sandbox read-only --skip-git-repo-check --json --output-schema %s --output-last-message rounds/r0-%s.last.json "$(cat rounds/r0-%s.prompt.txt)"' \
        "$model" "$(slot_field "$slot_id" '.reasoning_effort // ""')" \
        "$(basename "$schema_file")" "$slot_id" "$slot_id"
      ;;
    opencode)
      printf 'opencode run "<instruction>" -f rounds/r0-%s.prompt.txt --agent %s -m %s --variant %s --format json' \
        "$slot_id" "$(slot_field "$slot_id" '.agent')" "$model" \
        "$(slot_field "$slot_id" '.variant // "default"')"
      ;;
  esac
}

# Strip each participant's own label out of its round-0 prompt; what remains must
# be identical across participants. If it is not, the comparison the whole tool
# rests on is invalid, so this is a hard failure and not a warning.
check_round0_prompt_parity() {
  local target="$1"
  local tmp
  tmp="$(mktemp -d)"
  local id
  local reference=""
  local mismatch=0
  for id in "${DEBATER_IDS[@]}"; do
    local label label_escaped
    label="$(slot_field "$id" '.label')"
    # The label comes from roster JSON, and the schema does not constrain its
    # characters. Interpolated raw, a label containing a regex metacharacter or
    # the '/' delimiter either changes what the substitution matches or breaks
    # the sed expression outright. Escape both classes; '|' is the delimiter
    # below because it is likelier absent from a label than '/'.
    label_escaped="$(printf '%s' "$label" | sed -e 's/[.[\*^$()+?{}|]/\\&/g')"
    # Normalise away the two things that legitimately differ per harness: the
    # inline-schema block (only fenced_json slots carry one, because their
    # harness cannot be handed a schema) and the one-line schema instruction.
    # `cat -s` collapses the blank line the deleted block leaves behind; without
    # it this check fails on whitespace and teaches people to ignore it.
    sed -e "s|${label_escaped}|<SELF>|g" "$target/rounds/r0-${id}.prompt.txt" \
      | sed -e '/---BEGIN REQUIRED JSON SCHEMA---/,/---END REQUIRED JSON SCHEMA---/d' \
      | grep -v 'Your response must match the provided structured output schema' \
      | grep -v 'Your final response must be JSON matching the provided output schema' \
      | grep -v 'Your final response must be ONLY a single JSON object' \
      | cat -s \
        >"$tmp/$id.norm"
    if [[ -z "$reference" ]]; then
      reference="$tmp/$id.norm"
    elif ! diff -q "$reference" "$tmp/$id.norm" >/dev/null; then
      warn "round-0 prompt for '$id' differs from the reference beyond its own label:"
      diff "$reference" "$tmp/$id.norm" | sed -n '1,20p' >&2
      mismatch=1
    fi
  done
  rm -rf "$tmp"
  if [[ "$mismatch" -eq 1 ]]; then
    die "round-0 prompts are not equivalent across participants; the debate would not be a fair comparison"
  fi
  ok "round-0 prompt parity: all ${#DEBATER_IDS[@]} prompts identical modulo self-label and harness schema wording"
}

