# shellcheck shell=bash
# agent-kombat -- Per-harness argv, session capture, and structured-output extraction.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: SLOT_SESSION_ID, SLOT_VALIDATOR (both declared at file top
#   level here, under the `# --- dispatch ---` sub-header, and never assigned
#   again after that declaration in this file. SLOT_SESSION_ID is read by all
#   three adapters -- adapter_claude, adapter_codex, adapter_opencode.
#   SLOT_VALIDATOR is read only inside adapter_opencode's structured-retry
#   branch; adapter_claude and adapter_codex never reference it. Both are
#   WRITTEN by par_run in _lib/dispatch.sh -- ownership is split: declared
#   and read here, written there.)
# Reads globals owned elsewhere: MAX_ARGV_BYTES (entry file, top-level
#   default -- read only by guard_argv_size here; guard_argv_size was its
#   only reader anywhere in the script, so the entry-file declaration now
#   has no reader left there and needs an SC2034 disable), DEBUG_AGENT_CALLS
#   (entry file, top-level default -- read here only by adapter_claude; also
#   written elsewhere in the entry file (by parse_args's --debug-agent-calls
#   flag) and read by write_config in _lib/persistence.sh, so no single file
#   owns both sides and the declaration stays put), MAX_READS_PER_TURN (entry
#   file, top-level constant, never reassigned -- read here only by
#   warn_read_heavy_turn; also read by write_config in _lib/persistence.sh,
#   so it stays put too)

# Guard against double-sourcing.
[ -n "${_AK_ADAPTERS_SOURCED:-}" ] && return 0
_AK_ADAPTERS_SOURCED=1

# ---------------------------------------------------------------------------
# Harness adapters
# ---------------------------------------------------------------------------
#
# Bash has no interfaces, so the abstraction is a uniform signature plus a case
# dispatch, with ONE normalisation guarantee. On success every adapter leaves:
#
#   <out_prefix>.raw          harness-native stdout, kept for audit
#   <out_prefix>.stderr       harness stderr
#   <out_prefix>.turn.json    a plain JSON object matching the phase schema
#   <out_prefix>.session-id   the session/thread id, for the next round's resume
#
# That normalisation is the whole trick: after it, the validators, manifests and
# loops are harness-agnostic and only the pre-normalisation step differs.
#
# Adapters run as background children, one per slot per round, so they must not
# touch events.jsonl -- they log to their own per-slot event file, which the
# round barrier merges (see merge_round_events).

uuid() {
  if have uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return
  fi
  # No uuidgen and no kernel UUID source. The claude CLI validates --session-id
  # as a real UUID, so the value must have the 8-4-4-4-12 lowercase-hex shape,
  # not merely be unique. openssl is the portable source; $RANDOM is the last
  # resort (low entropy, but uniqueness within a single run is all we need).
  local hex=""
  if have openssl; then
    hex="$(openssl rand -hex 16)"
  else
    local _i
    for _i in 1 2 3 4; do
      hex+="$(printf '%08x' "$(( (RANDOM << 15) | RANDOM ))")"
    done
  fi
  printf '%s-%s-%s-%s-%s\n' \
    "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

guard_argv_size() {
  local prompt_file="$1"
  local slot_id="$2"
  local size
  size="$(file_size_bytes "$prompt_file")"
  if [[ "$size" -gt "$MAX_ARGV_BYTES" ]]; then
    die "prompt for slot '$slot_id' is ${size} bytes, over the ${MAX_ARGV_BYTES}-byte argv budget. macOS ARG_MAX counts argv PLUS the environment, so a large prompt fails as a cryptic E2BIG. Shrink the requirement, drop a participant, or raise AGENT_KOMBAT_MAX_ARGV_BYTES if you know the real limit here."
  fi
}

# --- claude -----------------------------------------------------------------

adapter_claude() {
  local mode="$1" slot_id="$2" prompt_file="$3" schema_file="$4" out_prefix="$5" event_file="$6"
  local model session_id
  model="$(slot_field "$slot_id" '.model')"

  local schema_args=()
  if [[ -s "$schema_file" ]]; then
    schema_args=(--json-schema "$(jq -c . "$schema_file")")
  fi
  local debug_args=()
  if [[ "$DEBUG_AGENT_CALLS" -eq 1 ]]; then
    debug_args=(--debug-file "${out_prefix}.debug.log")
  fi

  local session_args=()
  if [[ "$mode" == "resume" ]]; then
    session_id="$SLOT_SESSION_ID"
    [[ -n "$session_id" && "$session_id" != "null" ]] \
      || die "slot '$slot_id' has no claude session id to resume"
    session_args=(--resume "$session_id")
  else
    session_id="$(uuid)"
    session_args=(--session-id "$session_id")
  fi

  # No guard_argv_size: the prompt goes on stdin, so ARG_MAX cannot apply here.

  # An explicit READ-ONLY tool allowlist, not `--tools ""`.
  #
  # `--tools ""` was the original read-only guarantee, and it worked -- but it
  # also stripped Read, Grep and Glob, so the claude participant could not check
  # a single repo fact. The first real debate diagnosed that about itself; the
  # judge recorded: "The entire factual base is single-sourced. A states it could
  # not read files in any round." Meanwhile codex had --sandbox read-only and
  # opencode had read/grep/glob, so both could verify while claude guessed. An
  # ungrounded participant weakens exactly the heterogeneity the tool sells.
  #
  # Verified both halves before changing it:
  #   --tools "Read,Grep,Glob" + "grep AGENTS.md for 'migration'" -> answered 13
  #   same list + "create tmp/probe.txt"                          -> "CANNOT. No
  #     file creation tool available... Write/Edit tools aren't surfaced", and no
  #     file appeared.
  #
  # Write, Edit, Bash, Task and Skill all stay absent, so a debater still cannot
  # touch the tree and cannot recurse back into this skill to fan out. Secrets
  # stay covered by the committed .claude/settings.json deny on Read(**/.env).
  local readonly_tools="Read,Grep,Glob"
  #
  # Prompt on STDIN, not as an argv string.
  #
  # Upstream passes "$(cat "$prompt_file")" as a positional. That works for a
  # small round-0 prompt and fails for a real debate round: at N=3 a participant
  # receives its own plan plus both competitors', which measured 66,835 bytes
  # here, and the argv form then returns
  #   subtype=error_max_structured_output_retries
  #   terminal_reason=structured_output_retry_exhausted
  #   duration_api_ms=0, every token counter 0, cost $0
  # i.e. five attempts that never reached a model. Byte-identical prompt on stdin:
  # is_error=false, 12,894 output tokens. Not a schema fault -- the same schema
  # succeeds with a short prompt -- and not ARG_MAX either, since 66KB is far
  # under it and the failure is structured-output exhaustion rather than E2BIG.
  #
  # The prompt only grows with participant count and plan verbosity, so argv was
  # never viable for the mesh topology.
  # Retry ONCE on a transient upstream error.
  #
  # `claude` exits 0 for these, reporting the failure in the payload instead:
  #   is_error=true, terminal_reason=api_error,
  #   result="API Error: Connection closed mid-response..."
  # Observed on a long opus revision: 80s of streaming, then the connection
  # dropped, 0 usable output, $1.07 billed. The longer a participant's answer,
  # the wider that window -- and a debate is exactly the workload that produces
  # long answers, so a dropped connection must not cost a whole round.
  #
  # Deliberately narrow: ONLY terminal_reason=api_error retries. A schema
  # rejection, a refusal or a session mismatch are all reproducible, so retrying
  # them just burns money twice. Each attempt is billed, so the budget is 1.
  local attempts="${AGENT_KOMBAT_CLAUDE_API_RETRIES:-1}"
  local try=0
  while :; do
    (( try > 0 )) && accumulate_read_calls "$out_prefix"
    if ! claude -p \
      --model "$model" \
      "${debug_args[@]}" \
      "${session_args[@]}" \
      --tools "$readonly_tools" \
      --output-format json \
      "${schema_args[@]}" \
      <"$prompt_file" >"${out_prefix}.raw" 2>"${out_prefix}.stderr"; then
      log_event_file "$event_file" "agent.harness.failed" \
        "$(jq -n --arg slot "$slot_id" --arg harness claude '{slot: $slot, harness: $harness}')"
      return 1
    fi

    local term
    term="$(jq -r '.terminal_reason // ""' "${out_prefix}.raw" 2>/dev/null || printf '')"
    if [[ "$term" != "api_error" ]]; then
      break
    fi

    if [[ "$try" -ge "$attempts" ]]; then
      warn "slot '$slot_id': claude returned a transient api_error and the retry budget ($attempts) is spent: $(jq -r '.result // "no detail"' "${out_prefix}.raw" 2>/dev/null)"
      log_event_file "$event_file" "agent.api_error.exhausted" \
        "$(jq -n --arg slot "$slot_id" --argjson attempts "$((try + 1))" \
          --arg detail "$(jq -r '.result // ""' "${out_prefix}.raw" 2>/dev/null)" \
          '{slot: $slot, attempts: $attempts, detail: $detail}')"
      return 1
    fi

    try="$((try + 1))"
    warn "slot '$slot_id': transient api_error, retrying ($try of $attempts). Each attempt is billed."
    log_event_file "$event_file" "agent.api_error.retry" \
      "$(jq -n --arg slot "$slot_id" --argjson attempt "$try" \
        --arg detail "$(jq -r '.result // ""' "${out_prefix}.raw" 2>/dev/null)" \
        '{slot: $slot, attempt: $attempt, detail: $detail}')"
    cp "${out_prefix}.raw" "${out_prefix}.api-error-${try}.raw" 2>/dev/null || true
    # A fresh session per attempt: the aborted one may hold a partial turn, and
    # resuming into that would splice half an answer onto the retry.
    if [[ "$mode" != "resume" ]]; then
      session_id="$(uuid)"
      session_args=(--session-id "$session_id")
    fi
    sleep 5
  done

  jq -e --arg id "$session_id" '.session_id == $id or .sessionId == $id' "${out_prefix}.raw" >/dev/null \
    || {
      # Not cosmetic: a silently-fresh session turns a debate into N independent
      # monologues, which is the exact failure this tool exists to prevent.
      log_event_file "$event_file" "agent.session.mismatch" \
        "$(jq -n --arg slot "$slot_id" --arg expected "$session_id" '{slot: $slot, expected_session_id: $expected}')"
      return 1
    }
  printf '%s\n' "$session_id" >"${out_prefix}.session-id"

  if [[ -s "$schema_file" ]]; then
    extract_claude_structured "${out_prefix}.raw" >"${out_prefix}.turn.json" || return 1
  else
    # Synthesis: the deliverable is markdown, not JSON.
    jq -er '.result | select(type == "string" and length > 0)' "${out_prefix}.raw" \
      >"${out_prefix}.md" || return 1
  fi
  return 0
}

extract_claude_structured() {
  local file="$1"
  jq -e '
    if (.structured_output | type) == "object" then
      .structured_output
    elif (.result | type) == "object" then
      .result
    elif (.result | type) == "string" then
      (.result | fromjson)
    else
      empty
    end
  ' "$file"
}

# --- codex ------------------------------------------------------------------

adapter_codex() {
  local mode="$1" slot_id="$2" prompt_file="$3" schema_file="$4" out_prefix="$5" event_file="$6"
  local model effort session_id
  model="$(slot_field "$slot_id" '.model')"
  effort="$(slot_field "$slot_id" '.reasoning_effort // ""')"

  local effort_args=()
  # D3. Without this, every codex call silently inherits
  # model_reasoning_effort from ~/.codex/config.toml (xhigh on this machine),
  # so cost and latency depend on a file outside the repo.
  [[ -z "$effort" ]] || effort_args=(-c "model_reasoning_effort=\"$effort\"")

  local schema_args=()
  [[ ! -s "$schema_file" ]] || schema_args=(--output-schema "$schema_file")

  guard_argv_size "$prompt_file" "$slot_id"

  local last_message="${out_prefix}.last.json"

  if [[ "$mode" == "resume" ]]; then
    session_id="$SLOT_SESSION_ID"
    [[ -n "$session_id" && "$session_id" != "null" ]] \
      || die "slot '$slot_id' has no codex thread id to resume"
    # `codex exec resume` has no -s/--sandbox (verified on 0.145.0), so the
    # sandbox has to be set through -c, exactly as upstream does. D2: upstream
    # omits --output-schema here, leaving its resume rounds schema-hoped rather
    # than schema-enforced; 0.145.0 accepts it, so we pass it.
    if ! codex exec resume \
      -c 'sandbox_mode="read-only"' \
      "${effort_args[@]}" \
      --model "$model" \
      --skip-git-repo-check \
      --json \
      "${schema_args[@]}" \
      --output-last-message "$last_message" \
      "$session_id" \
      "$(cat "$prompt_file")" \
      </dev/null >"${out_prefix}.raw" 2>"${out_prefix}.stderr"; then
      log_event_file "$event_file" "agent.harness.failed" \
        "$(jq -n --arg slot "$slot_id" --arg harness codex '{slot: $slot, harness: $harness}')"
      return 1
    fi
    jq -e --arg id "$session_id" 'select(.type == "thread.started") | .thread_id == $id' \
      "${out_prefix}.raw" >/dev/null || {
      log_event_file "$event_file" "agent.session.mismatch" \
        "$(jq -n --arg slot "$slot_id" --arg expected "$session_id" '{slot: $slot, expected_session_id: $expected}')"
      return 1
    }
  else
    if ! codex exec \
      --model "$model" \
      "${effort_args[@]}" \
      --sandbox read-only \
      --skip-git-repo-check \
      --json \
      "${schema_args[@]}" \
      --output-last-message "$last_message" \
      "$(cat "$prompt_file")" \
      </dev/null >"${out_prefix}.raw" 2>"${out_prefix}.stderr"; then
      log_event_file "$event_file" "agent.harness.failed" \
        "$(jq -n --arg slot "$slot_id" --arg harness codex '{slot: $slot, harness: $harness}')"
      return 1
    fi
    session_id="$(extract_codex_session_id "${out_prefix}.raw")"
    [[ -n "$session_id" ]] || {
      log_event_file "$event_file" "agent.session.missing" \
        "$(jq -n --arg slot "$slot_id" '{slot: $slot, detail: "no thread.started.thread_id in JSONL"}')"
      return 1
    }
  fi

  printf '%s\n' "$session_id" >"${out_prefix}.session-id"

  if [[ -s "$schema_file" ]]; then
    [[ -s "$last_message" ]] || return 1
    jq -e . "$last_message" >"${out_prefix}.turn.json" || return 1
  else
    [[ -s "$last_message" ]] || return 1
    cp "$last_message" "${out_prefix}.md"
  fi
  return 0
}

extract_codex_session_id() {
  local file="$1"
  jq -rn 'first(inputs | select(.type == "thread.started") | .thread_id? | select(type == "string")) // empty' \
    "$file" 2>/dev/null || true
}

# --- opencode ---------------------------------------------------------------
#
# The awkward one. opencode 1.18.8 has no --output-schema and no read-only
# sandbox flag, so this adapter carries two mitigations that the other two
# harnesses get for free:
#
#   * structured output      -> schema inlined in the prompt, then a four-layer
#                               extraction, then a bounded re-ask
#   * read-only guarantee    -> --agent <roster agent>, whose permission set
#                               denies everything but read/grep/glob/list
#
# Deliberately NOT using `ooy` / OPENCODE_YOLO=true / --auto here, which is a
# divergence from the glm-delegate skill's precedent: --auto auto-approves every
# permission that is not explicitly denied, which is exactly backwards for a
# plan-only debate.

adapter_opencode() {
  local mode="$1" slot_id="$2" prompt_file="$3" schema_file="$4" out_prefix="$5" event_file="$6"
  local model agent variant max_reask session_id
  model="$(slot_field "$slot_id" '.model')"
  agent="$(slot_field "$slot_id" '.agent')"
  variant="$(slot_field "$slot_id" '.variant // ""')"
  max_reask="$(slot_field "$slot_id" '.max_reask // 1')"

  local variant_args=()
  [[ -z "$variant" ]] || variant_args=(--variant "$variant")

  local session_args=()
  if [[ "$mode" == "resume" ]]; then
    session_id="$SLOT_SESSION_ID"
    [[ -n "$session_id" && "$session_id" != "null" ]] \
      || die "slot '$slot_id' has no opencode session id to resume"
    # Never --fork (branches the session and silently loses continuity) and
    # never -c/--continue (resolves "most recent session" GLOBALLY, which across
    # N concurrent slots is catastrophic cross-talk).
    session_args=(--session "$session_id")
  fi

  local attempt=0
  local active_prompt="$prompt_file"
  while :; do
    # The message positional MUST come before -f: `opencode run -f FILE MSG`
    # misparses and swallows the message as a second file argument. Attaching
    # with -f rather than inlining via "$(cat ...)" also sidesteps ARG_MAX,
    # which is why this harness needs no guard_argv_size call.
    (( attempt > 0 )) && accumulate_read_calls "$out_prefix"
    if ! opencode run \
      "Follow the instructions in the attached file. Reply with the JSON object it asks for and nothing else." \
      -f "$active_prompt" \
      --agent "$agent" \
      -m "$model" \
      "${variant_args[@]}" \
      "${session_args[@]}" \
      --format json \
      </dev/null >"${out_prefix}.raw" 2>"${out_prefix}.stderr"; then
      log_event_file "$event_file" "agent.harness.failed" \
        "$(jq -n --arg slot "$slot_id" --arg harness opencode --argjson attempt "$attempt" \
          '{slot: $slot, harness: $harness, attempt: $attempt}')"
      return 1
    fi

    # opencode's --agent fails OPEN: an unresolvable name prints "not found.
    # Falling back to default agent", silently uses `build` (which permits bash
    # and writes), and still exits 0. preflight_opencode_agents catches this
    # before the run starts; this catches a regression that appears mid-run.
    if grep -qi 'not found. Falling back' "${out_prefix}.stderr" "${out_prefix}.raw" 2>/dev/null; then
      log_event_file "$event_file" "agent.agent_fallback" \
        "$(jq -n --arg slot "$slot_id" --arg agent "$agent" \
          '{slot: $slot, requested_agent: $agent, detail: "opencode fell back to the default agent, which permits writes"}')"
      printf 'error: opencode did not resolve --agent %s and fell back to its default agent, which permits bash and file writes. Refusing this turn.\n' \
        "$agent" >&2
      return 1
    fi

    if [[ "$mode" != "resume" && -z "${session_id:-}" ]]; then
      session_id="$(extract_opencode_session_id "${out_prefix}.raw")"
      [[ -n "$session_id" ]] || {
        log_event_file "$event_file" "agent.session.missing" \
          "$(jq -n --arg slot "$slot_id" '{slot: $slot, detail: "no sessionID in opencode JSONL"}')"
        return 1
      }
      session_args=(--session "$session_id")
    fi

    # Markdown path FIRST. An empty schema file means "return the deliverable as
    # markdown, not JSON" (the synthesis phase). Gating that behind
    # extract_opencode_structured + a JSON validator made an opencode synthesizer
    # structurally impossible: a correct markdown answer failed, burned the
    # re-ask budget and returned 1. `structured_output: none` is legal on a
    # synthesizer slot, so this path has to actually work.
    if [[ ! -s "$schema_file" ]]; then
      if extract_opencode_text "${out_prefix}.raw" "$session_id" >"${out_prefix}.md" \
        && [[ -s "${out_prefix}.md" ]]; then
        printf '%s\n' "$session_id" >"${out_prefix}.session-id"
        return 0
      fi
      log_event_file "$event_file" "agent.extract.failed" \
        "$(jq -n --arg slot "$slot_id" '{slot: $slot, detail: "no markdown text recovered for a schema-less turn"}')"
      return 1
    fi

    if extract_opencode_structured "${out_prefix}.raw" "$session_id" >"${out_prefix}.turn.json" 2>/dev/null \
      && [[ -s "${out_prefix}.turn.json" ]] \
      && "$SLOT_VALIDATOR" "${out_prefix}.turn.json"; then
      if [[ "$attempt" -gt 0 ]]; then
        log_event_file "$event_file" "agent.reask.succeeded" \
          "$(jq -n --arg slot "$slot_id" --argjson attempt "$attempt" '{slot: $slot, attempt: $attempt}')"
      fi
      printf '%s\n' "$session_id" >"${out_prefix}.session-id"
      # Unreachable: the schema-less (synthesizer) case returns from the markdown
      # branch above, so $schema_file is non-empty by here. Kept as a pure move;
      # removing it is a behaviour-adjacent edit for a separate change.
      if [[ ! -s "$schema_file" ]]; then
        extract_opencode_text "${out_prefix}.raw" "$session_id" >"${out_prefix}.md"
      fi
      return 0
    fi

    attempt="$((attempt + 1))"
    if [[ "$attempt" -gt "$max_reask" ]]; then
      log_event_file "$event_file" "agent.reask.exhausted" \
        "$(jq -n --arg slot "$slot_id" --argjson attempts "$attempt" --arg raw "$(basename "${out_prefix}.raw")" \
          '{slot: $slot, attempts: $attempts, raw_path: $raw}')"
      # Fail loud. Upstream has no soft-fail path anywhere, and a soft fallback
      # here would let a malformed turn silently drop critique and
      # unresolved_issues -- quietly turning a debate into a monologue.
      return 1
    fi

    log_event_file "$event_file" "agent.reask.started" \
      "$(jq -n --arg slot "$slot_id" --argjson attempt "$attempt" '{slot: $slot, attempt: $attempt}')"
    active_prompt="${out_prefix}.reask-${attempt}.prompt.txt"
    build_opencode_reask_prompt "$schema_file" >"$active_prompt"
  done
}

build_opencode_reask_prompt() {
  local schema_file="$1"
  cat <<'PROMPT'
Your last message was not a valid JSON object for the required schema.

Reply with ONLY the JSON object. No prose, no preamble, no explanation, no
markdown code fence. The first character of your reply must be `{` and the last
must be `}`.
PROMPT
  if [[ -s "$schema_file" ]]; then
    printf '\n---BEGIN REQUIRED JSON SCHEMA---\n'
    jq . "$schema_file"
    printf -- '---END REQUIRED JSON SCHEMA---\n'
    printf '\nRequired top-level keys: %s\n' \
      "$(jq -r '.required | join(", ")' "$schema_file")"
  fi
}

extract_opencode_session_id() {
  local file="$1"
  jq -rn 'first(inputs | .sessionID? // .session_id? | select(type == "string")) // empty' \
    "$file" 2>/dev/null || true
}

# Layer 2 of the extraction: get the assistant's text out of opencode's output.
#
# VERIFIED against a real opencode 1.18.8 session (capture kept at
# testdata/fixtures/opencode-events-real.jsonl). The shape is:
#
#   {"type":"text","timestamp":N,"sessionID":"ses_...","part":{...,"text":"..."}}
#
# There is NO top-level `.text` -- the payload is at `.part.text`. An extractor
# written against the obvious `.text` returns an empty string on every real turn
# and then fails validation, which looks like a model problem rather than a
# parsing bug. The `.text //` first alternative is kept anyway in case a future
# version flattens it, and accessor (b) below is a genuinely independent path.
#
# Real streams also carry `tool_use`, `step_start` and `step_finish` events; a
# single round-0 turn produced 24 tool_use events against 7 text events, so
# filtering to text events is not optional.
extract_opencode_text() {
  local file="$1"
  local session_id="${2:-}"
  local text=""

  # (a) the event stream, tolerating three plausible payload key names
  text="$(jq -rn '
    [inputs | select(.type == "text" or .type == "message.part.updated")
            | (.text // .part.text // .content // empty)]
    | join("")
  ' "$file" 2>/dev/null || true)"
  if [[ -n "${text// /}" ]]; then
    printf '%s' "$text"
    return 0
  fi

  # (b) ask opencode for the session transcript. `opencode export` prints a
  # human "Exporting session: <id>" header before the JSON, so drop everything
  # up to the first line that starts with '{'.
  if [[ -n "$session_id" ]] && have opencode; then
    text="$(opencode export "$session_id" 2>/dev/null \
      | sed -n '/^{/,$p' \
      | jq -r '
        [.messages[] | select(.info.role == "assistant")]
        | last
        | [.parts[] | select(.type == "text") | .text]
        | join("")
      ' 2>/dev/null || true)"
    if [[ -n "${text// /}" ]]; then
      printf '%s' "$text"
      return 0
    fi
  fi

  # (c) last resort: any string-valued text-ish field anywhere in the stream.
  jq -rn '[inputs | .. | objects | .text? | select(type == "string")] | join("")' \
    "$file" 2>/dev/null || true
}

# Layer 3: coax a JSON object out of arbitrary model prose.
extract_opencode_structured() {
  local file="$1"
  local session_id="${2:-}"
  local text
  text="$(extract_opencode_text "$file" "$session_id")"
  [[ -n "${text// /}" ]] || return 1

  # (i) the whole thing already is JSON
  if printf '%s' "$text" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$text" | jq -c .
    return 0
  fi

  # (ii) fenced blocks, with an opener that MAY be typed and a closer that is bare.
  #
  # The previous version toggled on one pattern per pass, so with lang=json it
  # required the CLOSING fence to also read ```json. Real output closes with a bare
  # ```, so the block never terminated: `buf` ran to end-of-text and swallowed
  # every trailing line. That was masked because the `{...}` fallback usually
  # rescued it -- until any stray brace appeared after the fence, at which point
  # extraction failed outright. Verified: a payload followed by
  # "Trailing prose with { an unrelated brace }" extracted nothing at all.
  #
  # Correct grammar: ``` or ```<lang> opens, the next ``` closes regardless of the
  # opener's tag. Collect every complete block, then prefer the LAST one that
  # parses as an object -- models often narrate before the real answer.
  local fenced
  fenced="$(printf '%s' "$text" | awk '
    /^[[:space:]]*```/ {
      if (inblock) { inblock = 0; blocks[++n] = buf; buf = ""; next }
      inblock = 1; buf = ""; next
    }
    inblock { buf = buf $0 "\n"; next }
    END {
      # An unterminated final fence is still worth offering as a candidate.
      if (inblock && buf != "") blocks[++n] = buf
      for (i = n; i >= 1; i--) printf "%s\037", blocks[i]
    }
  ')"
  if [[ -n "$fenced" ]]; then
    local candidate
    while IFS= read -r -d $'\037' candidate; do
      [[ -n "${candidate// /}" ]] || continue
      if printf '%s' "$candidate" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$candidate" | jq -c .
        return 0
      fi
    done < <(printf '%s' "$fenced")
  fi

  # (iv) the widest {...} span, measured in CHARACTERS not lines.
  #
  # Line-wise slicing looks equivalent and is not: a model that answers
  # "I think the answer is {...} and that is my view." puts the JSON and trailing
  # prose on ONE line, so any line-granular span keeps the prose and fails to
  # parse. Slurping the whole text and cutting from the first '{' to the last '}'
  # handles the single-line and multi-line cases identically.
  # Done with bash parameter expansion rather than awk: slurping all input in awk
  # needs RS tricks that differ between GNU awk and the BSD awk on macOS, and
  # this is both portable and easier to read.
  local span=""
  if [[ "$text" == *'{'* && "$text" == *'}'* ]]; then
    span="{${text#*\{}"   # from the first '{'
    span="${span%\}*}}"   # to the last '}'
  fi
  if [[ -n "${span// /}" ]] && printf '%s' "$span" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$span" | jq -c .
    return 0
  fi

  return 1
}

# --- dispatch ---------------------------------------------------------------

# SLOT_SESSION_ID and SLOT_VALIDATOR are set by the caller immediately before
# dispatch. They are globals rather than parameters because the adapters already
# take six positional arguments and these two are read in exactly one place each.
SLOT_SESSION_ID=""
SLOT_VALIDATOR="validate_debater_response"

# count_read_tool_calls -- scans a harness raw-output file and counts read-like
# tool calls (read, grep, glob, list, search, view_file). Matches the streaming
# JSONL event traces emitted by opencode and codex. claude is a structural
# no-op here: its adapter uses --output-format json, a single result object
# (.session_id, .terminal_reason, .result, .structured_output) with no
# tool-call trace, so the regex can never match anything in a real claude .raw.
# The opencode/codex shapes are inferred from the adapters' event handling (see
# the tool_use note in extract_opencode_text), not yet confirmed against a
# captured tool-call event -- the checked-in opencode fixture carries only
# text/step events.
count_read_tool_calls() {
  local raw_file="$1"
  [[ -s "$raw_file" ]] || { printf '0'; return; }
  local n
  n="$(grep -ciE '"(tool|name|type)"\s*:\s*"[^"]*(read|grep|glob|list|search|view_file)' "$raw_file" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

# accumulate_read_calls -- add the read-tool-call count of the current
# ${out_prefix}.raw to the persistent ${out_prefix}.reads accumulator. Adapters
# call this before overwriting .raw on a re-ask or api-error retry, so the count
# from the overwritten attempt survives and warn_read_heavy_turn sees the
# aggregate across every attempt in the turn rather than only the final one.
accumulate_read_calls() {
  local out_prefix="$1"
  local acc_file="${out_prefix}.reads"
  local prev=0
  [[ -s "$acc_file" ]] && prev="$(<"$acc_file")"
  local cur
  cur="$(count_read_tool_calls "${out_prefix}.raw")"
  printf '%s' "$(( prev + cur ))" >"$acc_file"
}

# warn_read_heavy_turn -- called after a turn completes (success path in
# harness_send, timeout-kill path in par_run). If the total read-like tool calls
# across all attempts (accumulated prior attempts plus the final raw) exceeds
# MAX_READS_PER_TURN, logs a warning event so the pattern is visible in the
# round manifest and event log. The timeout path is the more important call
# site: a read-loop that burns through the wall-clock budget is the single most
# likely real-world manifestation, and without this call it would produce an
# agent.process.timeout with no read-count diagnostic. For opencode the partial
# .raw has streaming tool-call events even mid-kill; claude buffers to the end
# (.raw is empty here, so the call is a no-op for it).
warn_read_heavy_turn() {
  local slot_id="$1" out_prefix="$2" event_file="$3"
  local raw_file="${out_prefix}.raw"
  [[ -s "$raw_file" ]] || return 0
  local acc=0 final count
  [[ -s "${out_prefix}.reads" ]] && acc="$(<"${out_prefix}.reads")"
  final="$(count_read_tool_calls "$raw_file")"
  count=$(( acc + final ))
  [[ "$count" -gt "$MAX_READS_PER_TURN" ]] || return 0
  warn "$slot_id made $count read-like tool calls (budget: $MAX_READS_PER_TURN) -- possible read loop"
  log_event_file "$event_file" "agent.read_heavy_turn" "$(jq -n \
    --arg slot "$slot_id" \
    --argjson read_count "$count" \
    --argjson budget "$MAX_READS_PER_TURN" \
    '{slot: $slot, read_count: $read_count, budget: $budget}')"
}

harness_send() {
  local mode="$1" slot_id="$2" prompt_file="$3" schema_file="$4" out_prefix="$5" event_file="$6"
  local harness
  harness="$(slot_field "$slot_id" '.harness')"

  log_event_file "$event_file" "agent.call.started" "$(jq -n \
    --arg slot "$slot_id" --arg harness "$harness" --arg mode "$mode" \
    --arg model "$(slot_field "$slot_id" '.model')" \
    --arg prompt_sha "$(sha256_file "$prompt_file")" \
    '{slot: $slot, harness: $harness, mode: $mode, model: $model, prompt_sha256: $prompt_sha}')"

  # Reset the per-turn read accumulator before the adapter runs. Adapters
  # accumulate into .reads on each re-ask/retry overwrite; warn_read_heavy_turn
  # (called below on success) sums it with the final raw's count.
  : >"${out_prefix}.reads"
  local rc=0
  case "$harness" in
    claude) adapter_claude "$@" || rc=$? ;;
    codex) adapter_codex "$@" || rc=$? ;;
    opencode) adapter_opencode "$@" || rc=$? ;;
    *) die "no adapter for harness '$harness'" ;;
  esac

  if [[ "$rc" -eq 0 ]]; then
    log_event_file "$event_file" "agent.call.completed" \
      "$(jq -n --arg slot "$slot_id" --arg harness "$harness" '{slot: $slot, harness: $harness}')"
    warn_read_heavy_turn "$slot_id" "$out_prefix" "$event_file"
  else
    log_event_file "$event_file" "agent.call.failed" \
      "$(jq -n --arg slot "$slot_id" --arg harness "$harness" --argjson rc "$rc" \
        '{slot: $slot, harness: $harness, rc: $rc}')"
  fi
  printf '%s\n' "$rc" >"${out_prefix}.rc"
  return "$rc"
}
