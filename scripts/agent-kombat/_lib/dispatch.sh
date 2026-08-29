# shellcheck shell=bash
# agent-kombat -- Parallel in-round dispatch and barrier merge.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: PAR_SLOT, PAR_MODE, PAR_PROMPT, PAR_SCHEMA, PAR_PREFIX,
#   PAR_EVENT, PAR_IDLE, PAR_SESSION, PAR_VALIDATOR (all nine declared at
#   file top level here; reset by par_reset, appended to by par_add, and
#   read throughout par_run and by collect_session_ids -- no reader exists
#   anywhere else in the tree)
# Reads globals owned elsewhere: COLOR_DIM, COLOR_RESET (common.sh -- read
#   only by par_run, in its failure-reporting loop), HEARTBEAT_INTERVAL,
#   HARD_READ_LIMIT, DEFAULT_IDLE_TIMEOUT (entry file, top-level defaults
#   written only by parse_args there -- HEARTBEAT_INTERVAL and HARD_READ_LIMIT
#   read here by par_run, DEFAULT_IDLE_TIMEOUT read here by slot_idle_timeout),
#   SLOT_SESSION_ID,
#   SLOT_VALIDATOR (declared in _lib/adapters.sh, defaulted there -- WRITTEN
#   here by par_run, immediately before the dispatch subshell fork, so the
#   forked child inherits them; not read anywhere in this file, only in the
#   three adapters in _lib/adapters.sh)

# Guard against double-sourcing.
[ -n "${_AK_DISPATCH_SOURCED:-}" ] && return 0
_AK_DISPATCH_SOURCED=1

# ---------------------------------------------------------------------------
# Parallel in-round dispatch
# ---------------------------------------------------------------------------
#
# D13. Upstream dispatches a round's agents SEQUENTIALLY (run_round0 calls
# run_claude_round0 then run_codex_round0, ~L1946-1947). Within a round the
# participants are genuinely independent -- the only real dependency is the
# round barrier -- so they run concurrently here, which turns an N-times-serial
# wait into roughly one agent's latency.
#
# Two mechanisms that upstream did not need:
#
#   1. Per-slot event files, merged deterministically at the barrier. See the
#      note above merge_round_events.
#   2. N concurrent watchdogs. Upstream's run_with_heartbeat backgrounds ONE
#      process and polls it; this polls a set, tracks per-slot idleness against
#      each slot's own budget, and kills only the slot that stalled.
#
# What parallelism costs, stated honestly: interleaved harness stderr (mitigated
# by per-slot log files -- nothing shares a stream) and a real risk of resource
# storms when three agentic CLIs each spawn tool subprocesses at once.

declare -a PAR_SLOT=()
declare -a PAR_MODE=()
declare -a PAR_PROMPT=()
declare -a PAR_SCHEMA=()
declare -a PAR_PREFIX=()
declare -a PAR_EVENT=()
declare -a PAR_IDLE=()
declare -a PAR_SESSION=()
declare -a PAR_VALIDATOR=()

par_reset() {
  PAR_SLOT=()
  PAR_MODE=()
  PAR_PROMPT=()
  PAR_SCHEMA=()
  PAR_PREFIX=()
  PAR_EVENT=()
  PAR_IDLE=()
  PAR_SESSION=()
  PAR_VALIDATOR=()
}

par_add() {
  PAR_SLOT+=("$1")
  PAR_MODE+=("$2")
  PAR_PROMPT+=("$3")
  PAR_SCHEMA+=("$4")
  PAR_PREFIX+=("$5")
  PAR_EVENT+=("$6")
  PAR_IDLE+=("$7")
  PAR_SESSION+=("$8")
  PAR_VALIDATOR+=("$9")
}

slot_idle_timeout() {
  local slot_id="$1"
  local value
  value="$(slot_field "$slot_id" ".idle_timeout_seconds // $DEFAULT_IDLE_TIMEOUT")"
  printf '%s\n' "$value"
}

# Returns the number of failed slots. Never dies on a slot failure -- the caller
# decides, because a partial round is exactly what --resume exists to repair.
par_run() {
  local target="$1"
  local phase_label="$2"
  local count="${#PAR_SLOT[@]}"
  [[ "$count" -gt 0 ]] || return 0

  local -a pids=()
  local -a done_flag=()
  local -a status=()
  local start
  start="$(date +%s)"

  local i
  for ((i = 0; i < count; i++)); do
    # shellcheck disable=SC2034  # read by adapter_claude/adapter_codex/adapter_opencode in _lib/adapters.sh
    SLOT_SESSION_ID="${PAR_SESSION[$i]}"
    # shellcheck disable=SC2034  # read by adapter_opencode in _lib/adapters.sh
    SLOT_VALIDATOR="${PAR_VALIDATOR[$i]}"
    : >"${PAR_EVENT[$i]}"
    (
      harness_send \
        "${PAR_MODE[$i]}" \
        "${PAR_SLOT[$i]}" \
        "${PAR_PROMPT[$i]}" \
        "${PAR_SCHEMA[$i]}" \
        "${PAR_PREFIX[$i]}" \
        "${PAR_EVENT[$i]}"
    ) >"${PAR_PREFIX[$i]}.child.log" 2>&1 &
    pids+=("$!")
    done_flag+=(0)
    status+=(0)
    info "dispatched ${PAR_SLOT[$i]} ($(slot_field "${PAR_SLOT[$i]}" '.harness')) pid ${pids[$i]}"
  done

  local remaining="$count"
  local next_tick="$((start + HEARTBEAT_INTERVAL))"
  while [[ "$remaining" -gt 0 ]]; do
    local now
    now="$(date +%s)"
    for ((i = 0; i < count; i++)); do
      [[ "${done_flag[$i]}" -eq 0 ]] || continue
      local pid="${pids[$i]}"

      if ! kill -0 "$pid" 2>/dev/null; then
        local rc=0
        if wait "$pid"; then rc=0; else rc=$?; fi
        status[i]="$rc"
        done_flag[i]=1
        remaining="$((remaining - 1))"
        if [[ "$rc" -eq 0 ]]; then
          ok "${PAR_SLOT[$i]} finished ($(format_duration "$((now - start))"))"
        else
          warn "${PAR_SLOT[$i]} failed with status $rc after $(format_duration "$((now - start))")"
        fi
        continue
      fi

      # TOTAL WALL-CLOCK cap, not an inactivity cap. Inactivity is not a usable
      # signal for any of these harnesses:
      #
      #   claude   writes 0 bytes until it finishes  -> looks idle its whole run
      #   codex    writes {"type":"thread.started"} IMMEDIATELY, then nothing for
      #            minutes while it thinks -> looks "productive" for one line and
      #            idle ever after
      #   opencode streams, so inactivity would work -- for exactly one of three
      #
      # A first attempt branched on "has it produced anything yet", which rescued
      # claude and left codex still being false-killed: its 101-byte JSONL
      # preamble sets produced=1 in the first second, putting it straight back on
      # the inactivity path. Rather than keep guessing at what a meaningful byte
      # is per harness, time is the only honest signal, so the budget is elapsed
      # wall clock for every slot and inactivity is not consulted at all.
      #
      # Doubled because the roster budgets were written as inactivity numbers.
      local budget="${PAR_IDLE[$i]}"
      local limit="$((budget * 2))"
      if [[ "$budget" -gt 0 && "$((now - start))" -ge "$limit" ]]; then
        warn "${PAR_SLOT[$i]} exceeded its ${limit}s wall-clock budget; killing it"
        log_event_file "${PAR_EVENT[$i]}" "agent.process.timeout" "$(jq -n \
          --arg slot "${PAR_SLOT[$i]}" \
          --argjson elapsed_seconds "$((now - start))" \
          --argjson budget_seconds "$limit" \
          '{slot: $slot, elapsed_seconds: $elapsed_seconds, budget_seconds: $budget_seconds}')"
        terminate_process_tree "$pid"
        wait "$pid" 2>/dev/null || true
        # A read-loop that burns the wall-clock budget is the most likely
        # real-world manifestation of the exact failure this guard exists for.
        # opencode streams progressively, so the partial .raw has tool-call
        # events even mid-kill; claude buffers (.raw is empty, no-op here).
        warn_read_heavy_turn "${PAR_SLOT[$i]}" "${PAR_PREFIX[$i]}" "${PAR_EVENT[$i]}"
        status[i]=124
        done_flag[i]=1
        remaining="$((remaining - 1))"
      fi
    done

    if [[ "$remaining" -gt 0 && "$HEARTBEAT_INTERVAL" -gt 0 && "$now" -ge "$next_tick" ]]; then
      # Read-loop hard stop, on the heartbeat cadence so the growing .raw is
      # grepped once per heartbeat rather than every poll. A wall-clock kill
      # waits the full budget while a read loop streams tool calls the whole
      # time; counting reads on the partial .raw catches it in seconds. claude
      # buffers (.raw empty until finish) so its count is always 0 here.
      local j
      for ((j = 0; j < count; j++)); do
        [[ "${done_flag[$j]}" -eq 0 ]] || continue
        [[ "$HARD_READ_LIMIT" -gt 0 ]] || continue
        local reads
        reads="$(count_read_tool_calls "${PAR_PREFIX[$j]}.raw")"
        if [[ "$reads" -gt "$HARD_READ_LIMIT" ]]; then
          warn "${PAR_SLOT[$j]} exceeded the hard read limit (${reads} > ${HARD_READ_LIMIT}); killing it"
          log_event_file "${PAR_EVENT[$j]}" "agent.read_limit.killed" "$(jq -n \
            --arg slot "${PAR_SLOT[$j]}" \
            --argjson read_count "$reads" \
            --argjson limit "$HARD_READ_LIMIT" \
            '{slot: $slot, read_count: $read_count, limit: $limit}')"
          terminate_process_tree "${pids[$j]}"
          wait "${pids[$j]}" 2>/dev/null || true
          warn_read_heavy_turn "${PAR_SLOT[$j]}" "${PAR_PREFIX[$j]}" "${PAR_EVENT[$j]}"
          status[j]=124
          done_flag[j]=1
          remaining="$((remaining - 1))"
        fi
      done
      local waiting=()
      for ((i = 0; i < count; i++)); do
        [[ "${done_flag[$i]}" -eq 1 ]] || waiting+=("${PAR_SLOT[$i]}:$(human_size "$(file_size_bytes "${PAR_PREFIX[$i]}.raw")")")
      done
      # SKILL.md advertises bash >= 4.0, where expanding an empty array under
      # `set -u` is an unbound-variable error (fixed only in 4.4). Every slot
      # can be done here while the loop still ticks once, so guard it.
      if [[ "${#waiting[@]}" -gt 0 ]]; then
        info "$phase_label $(format_duration "$((now - start))") | waiting: ${waiting[*]}"
      else
        info "$phase_label $(format_duration "$((now - start))")"
      fi
      next_tick="$((now + HEARTBEAT_INTERVAL))"
    fi

    [[ "$remaining" -eq 0 ]] || sleep 0.3
  done

  local failures=0
  for ((i = 0; i < count; i++)); do
    if [[ "${status[$i]}" -ne 0 ]]; then
      failures="$((failures + 1))"
      # The child's own log is where an adapter's diagnostics land; surface a
      # bounded slice so a failure is diagnosable without hunting for files.
      if [[ -s "${PAR_PREFIX[$i]}.stderr" ]]; then
        printf '%s--- %s stderr (first 40 lines) ---%s\n' "$COLOR_DIM" "${PAR_SLOT[$i]}" "$COLOR_RESET" >&2
        sed -n '1,40p' "${PAR_PREFIX[$i]}.stderr" >&2
      fi
      if [[ -s "${PAR_PREFIX[$i]}.child.log" ]]; then
        printf '%s--- %s adapter log (first 20 lines) ---%s\n' "$COLOR_DIM" "${PAR_SLOT[$i]}" "$COLOR_RESET" >&2
        sed -n '1,20p' "${PAR_PREFIX[$i]}.child.log" >&2
      fi
    fi
  done
  return "$failures"
}

human_size() {
  local bytes="$1"
  if [[ "$bytes" -ge 1048576 ]]; then
    printf '%dMB' "$((bytes / 1048576))"
  elif [[ "$bytes" -ge 1024 ]]; then
    printf '%dKB' "$((bytes / 1024))"
  else
    printf '%dB' "$bytes"
  fi
}

# Persist the session ids the adapters wrote, so the next round can resume.
collect_session_ids() {
  local target="$1"
  local i
  for ((i = 0; i < ${#PAR_SLOT[@]}; i++)); do
    local file="${PAR_PREFIX[$i]}.session-id"
    [[ -f "$file" ]] || continue
    local sid
    sid="$(cat "$file")"
    [[ -n "$sid" ]] || continue
    update_config "$target" --arg slot "${PAR_SLOT[$i]}" --arg sid "$sid" \
      '.slots[$slot].session_id = $sid'
  done
}
