# shellcheck shell=bash
# agent-kombat -- Tool gates, the opencode agent canary, and --check-harnesses.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: none
# Reads globals owned elsewhere: none

# Guard against double-sourcing.
[ -n "${_AK_PREFLIGHT_SOURCED:-}" ] && return 0
_AK_PREFLIGHT_SOURCED=1

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

preflight_jq() {
  have jq || die "jq is required"
  have shasum || die "shasum is required"
}

# Which harnesses does the resolved roster actually need? Only check those --
# a duo roster should not fail because codex is absent.
roster_harnesses() {
  roster_slots_json | jq -r '[.[].harness] | unique | .[]'
}

tool_version() {
  local tool="$1"
  case "$tool" in
    claude) claude --version 2>/dev/null | head -1 ;;
    codex) codex --version 2>/dev/null | head -1 ;;
    opencode) opencode --version 2>/dev/null | head -1 ;;
    jq) jq --version 2>/dev/null | head -1 ;;
    *) printf 'unknown\n' ;;
  esac
}

preflight_tools() {
  local harness
  while IFS= read -r harness; do
    [[ -n "$harness" ]] || continue
    have "$harness" || die "roster requires '$harness' but it is not on PATH"
  done < <(roster_harnesses)
  preflight_opencode_agents
}

# Verify every opencode slot's agent actually resolves, on EVERY run.
#
# This is not defensive padding. `opencode run --agent <unknown>` does not fail:
# it prints "agent \"<name>\" not found. Falling back to default agent", silently
# uses `build` -- whose permission set is {"*": "allow"}, i.e. bash and write
# enabled -- and exits 0. So a typo in a personal roster, a renamed file, or any
# environment where .opencode/agent/*.md is not discovered would downgrade a
# read-only debater to a full-write one with no signal at all.
#
# assert_tree_untouched would eventually notice the damage; this prevents it.
#
# Prove the agent resolves by DISPATCHING, not by listing it.
#
# `opencode agent list` is flaky (measured 0 1 0 0 0 0 1 0 on an unchanged tree),
# so it cannot support a decision in either direction: refusing on it blocks valid
# runs, and warning-and-continuing is worse still, because
# `--agent <unresolvable>` fails OPEN -- opencode falls back to `build`
# ({"*": "allow"}, bash and writes enabled) and exits 0. Detecting the
# `Falling back` line inside a real turn is POST-HOC: by then the write-capable
# agent has already executed. So is assert_tree_untouched.
#
# A canary dispatch is the only check that observes the same code path the debate
# will use, before the debate runs. It costs a two-token reply on the slot's real
# model and it is authoritative.
#
# Exit codes are NOT boolean, because the two ways this fails need different
# diagnostics and point at different files:
#   0  agent resolved and the model answered
#   2  agent did NOT resolve -- opencode fell back to the write-capable 'build'
#      agent and still exited 0. Containment is the problem; check the agent file.
#   1  anything else. Since the canary carries the slot's real model, the likely
#      cause is a rejected model id -- which fails outright with NO fallback (a
#      bogus id answers `Unexpected server error`, rc=1). Blaming the agent file
#      here would send the operator to the wrong file entirely.
opencode_agent_proven() {
  local want="$1"
  local model="$2"
  local probe_out
  probe_out="$(mktemp)"
  local rc=0
  opencode run "Reply with exactly: ok" \
    --agent "$want" -m "$model" --format json \
    </dev/null >"$probe_out" 2>&1 || rc=$?
  if grep -qi 'not found. Falling back' "$probe_out"; then
    rm -f "$probe_out"
    return 2
  fi
  rm -f "$probe_out"
  [[ "$rc" -eq 0 ]]
}

preflight_opencode_agents() {
  roster_harnesses | grep -qx opencode || return 0
  if [[ "${AGENT_KOMBAT_SKIP_OPENCODE_CANARY:-0}" == "1" ]]; then
    warn "AGENT_KOMBAT_SKIP_OPENCODE_CANARY=1: the read-only opencode agent is NOT proven. Only set this when you have verified it another way."
    return 0
  fi

  # One canary per distinct {agent, model} pair, NOT per agent.
  #
  # Each dispatch carries the slot's OWN model, unmodified. This used to rewrite
  # the id to a cheaper sibling (`${model%%-fast}-fast`), which only worked because
  # the opencode slot was GLM and `zai/glm-5.2-fast` happened to exist. DeepSeek has
  # no such suffix -- its cheap tier is `deepseek/deepseek-v4-flash`, so the rewrite
  # produced `deepseek/deepseek-v4-pro-fast`, which the provider rejects with a
  # generic "Unexpected server error". That turned a working roster into a refusal
  # whose message blamed the agent, not the model id.
  #
  # Paying full price for a two-token canary buys a second guarantee beyond agent
  # resolution: the model id itself resolves. That guarantee is per-model, so
  # grouping by agent alone would leave every model after the first untested --
  # `deepseek-only` runs two models behind one agent, and its second slot would
  # have failed mid-debate instead of at preflight.
  local want model slots
  while IFS=$'\t' read -r want model slots; do
    [[ -n "$want" ]] || continue
    [[ -n "$model" ]] || die "opencode slot(s) '${slots}' name agent '$want' with no model; cannot prove the read-only agent without one"
    local probe_rc=0
    opencode_agent_proven "$want" "$model" || probe_rc=$?
    if [[ "$probe_rc" -eq 0 ]]; then
      ok "opencode agent '$want' on '$model' PROVEN by canary dispatch (slots: ${slots}; read-only guarantee in place)"
    elif [[ "$probe_rc" -eq 2 ]]; then
      die "opencode agent '$want' did not resolve on a canary dispatch (slots: ${slots}), so opencode would fall back to the write-capable 'build' agent. Refusing rather than discovering it mid-debate, after that agent has already run.
  Check:  ls .opencode/agent/${want}.md
  Debug:  opencode run 'hi' --agent ${want} -m ${model} --format json 2>&1 | head
  Or run a roster with no opencode slot:  --roster pair"
    else
      die "canary dispatch failed for model '$model' on agent '$want' (slots: ${slots}). The agent resolved, so this is the model or the provider -- a rejected model id fails outright with no fallback. Refusing before any debate dispatch.
  Check:  opencode models | grep -F '${model}'
  Debug:  opencode run 'hi' --agent ${want} -m ${model} --format json 2>&1 | head
  Fix:    correct the model on slot(s) '${slots}', or override with --model <slot>=<model>"
    fi
  done < <(opencode_canary_targets)
}

# Distinct {agent, model} pairs across every opencode slot, as
# `agent<TAB>model<TAB>slot_ids`. Naming the slots keeps a failure actionable: the
# pair alone does not say which roster entry to go and fix.
opencode_canary_targets() {
  roster_slots_json | jq -r '
    [.[] | select(.harness == "opencode")]
    | group_by([.agent, .model])
    | .[]
    | [(.[0].agent // ""), (.[0].model // ""), ([.[].id] | join(","))]
    | @tsv'
}

# --check-harnesses: the three CLIs ship on independent release cadences and any
# of them can rename a flag out from under us. This greps each --help for every
# flag the adapters depend on, so a breaking upstream change is a clear message
# instead of a mid-debate failure. Costs nothing.
run_check_harnesses() {
  local failures=0
  local harness

  check_flag() {
    local tool="$1"
    local help_cmd="$2"
    local flag="$3"
    if printf '%s' "$help_cmd" | bash 2>&1 | grep -q -- "$flag"; then
      ok "$tool $flag"
    else
      warn "$tool is missing the flag this port depends on: $flag"
      failures="$((failures + 1))"
    fi
  }

  while IFS= read -r harness; do
    [[ -n "$harness" ]] || continue
    have "$harness" || {
      warn "$harness not on PATH"
      failures="$((failures + 1))"
      continue
    }
    step "$harness $(tool_version "$harness")"
    case "$harness" in
      claude)
        check_flag claude 'claude --help' '--json-schema'
        check_flag claude 'claude --help' '--output-format'
        check_flag claude 'claude --help' '--session-id'
        check_flag claude 'claude --help' '--resume'
        check_flag claude 'claude --help' '--tools'
        ;;
      codex)
        check_flag codex 'codex exec --help' '--output-schema'
        check_flag codex 'codex exec --help' '--output-last-message'
        check_flag codex 'codex exec --help' '--skip-git-repo-check'
        check_flag codex 'codex exec --help' '--json'
        check_flag 'codex resume' 'codex exec resume --help' '--output-schema'
        check_flag 'codex resume' 'codex exec resume --help' '--output-last-message'
        ;;
      opencode)
        check_flag opencode 'opencode run --help' '--session'
        check_flag opencode 'opencode run --help' '--agent'
        check_flag opencode 'opencode run --help' '--format'
        check_flag opencode 'opencode run --help' '--file'
        # Asserted ABSENT rather than present: if opencode ever gains real
        # structured output, the fenced_json fallback should be retired, and
        # this is where we would find out.
        if opencode run --help 2>&1 | grep -q -- '--output-schema'; then
          warn "opencode now has --output-schema: the fenced_json adapter can be replaced by native structured output (see UPSTREAM.md)"
        else
          info "opencode has no --output-schema (expected); fenced_json extraction is required"
        fi
        ;;
    esac
  done < <(roster_harnesses)

  # The read-only opencode agent is load-bearing, so PROVE it the same way
  # preflight does -- a canary dispatch.
  #
  # This used one `opencode agent list` sample and was therefore a coin flip: a
  # reviewer saw the listing find kombat-debater and the very next
  # `--check-harnesses` report it unregistered and exit 2. A diagnostic that
  # contradicts itself between consecutive runs is worse than none, because it
  # trains people to ignore it.
  if roster_harnesses | grep -qx opencode; then
    # Same coverage as preflight_opencode_agents: one dispatch per distinct
    # {agent, model} pair, each on the slot's own model. A diagnostic that probes
    # fewer configurations than the debate will use reports green on an untested one.
    local want_agent want_model want_slots
    while IFS=$'\t' read -r want_agent want_model want_slots; do
      [[ -n "$want_agent" ]] || continue
      if [[ -z "$want_model" ]]; then
        # Skip only this canary. Returning early here would jump past the
        # accumulated-failures check below and report a green harness run.
        warn "opencode slot(s) '${want_slots}' name agent '$want_agent' with no model; skipping the canary dispatch"
        continue
      fi
      info "proving opencode agent '$want_agent' by canary dispatch on $want_model (slots: ${want_slots}; a few tokens, the listing is too flaky to decide on)"
      local probe_rc=0
      opencode_agent_proven "$want_agent" "$want_model" || probe_rc=$?
      if [[ "$probe_rc" -eq 0 ]]; then
        ok "opencode agent '$want_agent' on '$want_model' PROVEN (read-only guarantee in place)"
      elif [[ "$probe_rc" -eq 2 ]]; then
        warn "opencode agent '$want_agent' did NOT resolve on a canary dispatch (slots: ${want_slots}): opencode would fall back to the write-capable 'build' agent. Check .opencode/agent/${want_agent}.md exists and parses."
        failures="$((failures + 1))"
      else
        warn "canary dispatch failed for model '$want_model' on agent '$want_agent' (slots: ${want_slots}). The agent resolved, so this is the model or the provider. Check the id with: opencode models | grep -F '${want_model}'"
        failures="$((failures + 1))"
      fi
    done < <(opencode_canary_targets)
  fi

  if [[ "$failures" -gt 0 ]]; then
    refuse "$failures harness check(s) failed"
  fi
  ok "all harness flags present"
}
