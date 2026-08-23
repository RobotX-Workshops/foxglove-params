# shellcheck shell=bash
# agent-kombat -- Debate contract, JSON schemas, and response validation.
#
# Sourced by agent-kombat.sh. No shebang, not executable: the caller owns
# `set -euo pipefail` and every path constant.
#
# Owns globals: CONTRACT_ID, CONTRACT_NOUN, CONTRACT_OUTPUT_FIELD,
#   CONTRACT_REVISED_FIELD, CONTRACT_FINAL_FILENAME, CONTRACT_FINAL_LABEL,
#   CONTRACT_CONTEXT_MODE, CONTRACT_INITIAL_TASK, CONTRACT_DEBATE_TASK,
#   CONTRACT_SYNTHESIS_TASK, CONTRACT_ROUND0_NOTE, CONTRACT_SYNTHESIS_NOTE,
#   CONTRACT_SOURCE (all thirteen declared at file top level here. load_contract
#   here writes all thirteen from the contract JSON; CONTRACT_CONTEXT_MODE is
#   then conditionally rewritten by normalise_context_mode's upstream-value
#   fallback branch, also here -- both read and write it. validate_contract_loaded
#   here reads CONTRACT_ID, CONTRACT_NOUN, CONTRACT_FINAL_LABEL,
#   CONTRACT_INITIAL_TASK, CONTRACT_DEBATE_TASK, CONTRACT_SYNTHESIS_TASK
#   directly, plus CONTRACT_OUTPUT_FIELD and CONTRACT_REVISED_FIELD indirectly
#   via validate_json_field_name and CONTRACT_FINAL_FILENAME indirectly via
#   validate_contract_filename. CONTRACT_OUTPUT_FIELD is also read by
#   round0_schema_file and validate_round0_response here; CONTRACT_REVISED_FIELD
#   by debater_schema_file and validate_debater_response here.
#   CONTRACT_ROUND0_NOTE, CONTRACT_SYNTHESIS_NOTE and CONTRACT_SOURCE are
#   written here but have no reader in this file -- CONTRACT_SOURCE is read by
#   print_roster in roster.sh, CONTRACT_ROUND0_NOTE by build_round0_prompt and
#   CONTRACT_SYNTHESIS_NOTE by build_synthesis_prompt, both in _lib/prompts.sh.
#   Separately, load_run_config in _lib/runmodes.sh is a second writer of all
#   thirteen on the --resume path; that is deliberate coupling, not an
#   ownership gap.)
# Reads globals owned elsewhere: CONTRACT_DIR (entry file, top-level constant
#   derived from SCRIPT_DIR -- read only by load_contract here, same shape as
#   ROSTER_DIR in roster.sh, so it stays put with its own SC2034 disable rather
#   than move), CONTRACT_SPEC (entry file -- default declaration plus a write in
#   parse_args; read only by load_contract here, so no single file owns both
#   sides and the declaration stays put)

# Guard against double-sourcing.
[ -n "${_AK_CONTRACTS_SOURCED:-}" ] && return 0
_AK_CONTRACTS_SOURCED=1

# Contract fields (populated by load_contract / load_run_config).
CONTRACT_ID=""
CONTRACT_NOUN=""
CONTRACT_OUTPUT_FIELD=""
CONTRACT_REVISED_FIELD=""
CONTRACT_FINAL_FILENAME=""
CONTRACT_FINAL_LABEL=""
CONTRACT_CONTEXT_MODE=""
CONTRACT_INITIAL_TASK=""
CONTRACT_DEBATE_TASK=""
CONTRACT_SYNTHESIS_TASK=""
CONTRACT_ROUND0_NOTE=""
CONTRACT_SYNTHESIS_NOTE=""
CONTRACT_SOURCE=""

# ---------------------------------------------------------------------------
# Contracts
# ---------------------------------------------------------------------------
#
# D4: upstream hardcodes its two builtin contracts in a bash case statement
# (load_builtin_contract, ~L737) and has a SECOND loader for --contract JSON
# files. Two loaders for the same shape is a drift class, so builtins are data
# files here and there is exactly one loader.

load_contract() {
  local spec="$CONTRACT_SPEC"
  local path=""
  case "$spec" in
    plan | artifact)
      path="$CONTRACT_DIR/${spec}.json"
      [[ -f "$path" ]] || die "missing builtin contract: $path"
      CONTRACT_SOURCE="builtin:$spec"
      ;;
    *)
      path="$spec"
      [[ -f "$path" ]] || die "contract not found: $path (want plan, artifact, or a path)"
      # shellcheck disable=SC2034  # read by print_roster in _lib/roster.sh
      CONTRACT_SOURCE="file:$path"
      ;;
  esac

  jq -e . "$path" >/dev/null 2>&1 || die "contract is not valid JSON: $path"

  CONTRACT_ID="$(jq -r '.id // ""' "$path")"
  CONTRACT_NOUN="$(jq -r '.noun // ""' "$path")"
  CONTRACT_OUTPUT_FIELD="$(jq -r '.output_field // ""' "$path")"
  CONTRACT_REVISED_FIELD="$(jq -r '.revised_field // ""' "$path")"
  CONTRACT_FINAL_FILENAME="$(jq -r '.final_filename // ""' "$path")"
  CONTRACT_FINAL_LABEL="$(jq -r '.final_label // ""' "$path")"
  CONTRACT_CONTEXT_MODE="$(jq -r '.context_mode // "file"' "$path")"
  CONTRACT_INITIAL_TASK="$(jq -r '.initial_task // ""' "$path")"
  CONTRACT_DEBATE_TASK="$(jq -r '.debate_task // ""' "$path")"
  CONTRACT_SYNTHESIS_TASK="$(jq -r '.synthesis_task // ""' "$path")"
  # shellcheck disable=SC2034  # read by build_round0_prompt in _lib/prompts.sh
  CONTRACT_ROUND0_NOTE="$(jq -r '.round0_note // ""' "$path")"
  # shellcheck disable=SC2034  # read by build_synthesis_prompt in _lib/prompts.sh
  CONTRACT_SYNTHESIS_NOTE="$(jq -r '.synthesis_note // ""' "$path")"

  normalise_context_mode
  validate_contract_loaded
}

# D6: plan_core.py is not ported, so upstream's "instructions" and "context"
# context modes -- which both meant "shell out to the Python classifier and
# render its output" -- collapse to "file" (inline the static shared context).
# Upstream contract JSONs still load; they just get a warning.
normalise_context_mode() {
  case "$CONTRACT_CONTEXT_MODE" in
    file | none) ;;
    instructions | context)
      warn "contract context_mode '$CONTRACT_CONTEXT_MODE' is an upstream value; treating it as 'file' (plan_core.py is not ported -- see UPSTREAM.md D6)"
      CONTRACT_CONTEXT_MODE="file"
      ;;
    *)
      die "contract context_mode must be file or none, got '$CONTRACT_CONTEXT_MODE'"
      ;;
  esac
}

validate_json_field_name() {
  local name="$1"
  local label="$2"
  [[ "$name" =~ ^[a-z][a-z0-9_]*$ ]] \
    || die "$label must be a lowercase snake_case JSON field name, got '$name'"
}

validate_contract_filename() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "contract final_filename must be a bare filename, got '$name'"
  [[ "$name" != *..* ]] || die "contract final_filename must not traverse: '$name'"
}

validate_contract_loaded() {
  [[ -n "$CONTRACT_ID" ]] || die "contract is missing 'id'"
  [[ -n "$CONTRACT_NOUN" ]] || die "contract is missing 'noun'"
  validate_json_field_name "$CONTRACT_OUTPUT_FIELD" "contract output_field"
  validate_json_field_name "$CONTRACT_REVISED_FIELD" "contract revised_field"
  validate_contract_filename "$CONTRACT_FINAL_FILENAME"
  [[ -n "$CONTRACT_FINAL_LABEL" ]] || die "contract is missing 'final_label'"
  [[ -n "$CONTRACT_INITIAL_TASK" ]] || die "contract is missing 'initial_task'"
  [[ -n "$CONTRACT_DEBATE_TASK" ]] || die "contract is missing 'debate_task'"
  [[ -n "$CONTRACT_SYNTHESIS_TASK" ]] || die "contract is missing 'synthesis_task'"
}

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------
#
# D14 note: the debater schema is byte-identical to upstream's apart from making
# strengths_to_steal and critique carry an attribution. At N>2 an unattributed
# critique is useless -- you cannot tell which competitor it is about -- and the
# judge's "agreements lacking justification" signal depends on knowing who said
# what. Everything else stays exactly as upstream had it.
#
# INVARIANT for every schema below: when an object sets additionalProperties
# false, `required` must list EVERY key in `properties`. Both providers' native
# structured-output modes reject a partial `required` outright, and they report it
# so differently that the shared cause is easy to miss:
#   codex  -> HTTP 400 invalid_json_schema, naming the absent key
#   claude -> error_max_structured_output_retries after 5 attempts, with
#             duration_api_ms and every token counter at 0 (the request never
#             reached a model, so nothing was billed)
# There is therefore no such thing as an optional field here. A field that may
# legitimately be empty is required-but-emptyable (an array that can be [], or a
# ["string","null"] union like focus_for_next_round) and its prompt must say so,
# or the model is forced to invent content to satisfy the schema.
#
# The fake harnesses under testdata/ cannot catch a violation: they emit whatever
# the driver's own prompts describe and never validate a schema, so this
# invariant is guarded by an assertion in smoke.sh instead.

round0_schema_file() {
  local target="$1"
  mkdir -p "$target/schemas"
  jq -n --arg field "$CONTRACT_OUTPUT_FIELD" '{
    type: "object",
    additionalProperties: false,
    properties: {
      ($field): {type: "string", minLength: 1}
    },
    required: [$field]
  }' >"$target/schemas/round0.schema.json"
}

debater_schema_file() {
  local target="$1"
  mkdir -p "$target/schemas"
  jq -n --arg field "$CONTRACT_REVISED_FIELD" '{
    type: "object",
    additionalProperties: false,
    properties: {
      strengths_to_steal: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            from: {type: "string"},
            strength: {type: "string"}
          },
          required: ["from", "strength"]
        }
      },
      ($field): {type: "string", minLength: 1},
      critique: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            target: {type: "string"},
            finding: {type: "string"}
          },
          required: ["target", "finding"]
        }
      },
      could_not_fault: {
        type: "array",
        items: {type: "string"}
      },
      unresolved_issues: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            issue: {type: "string"},
            why_it_matters: {type: "string"},
            suggested_test_or_decision_rule: {type: "string"}
          },
          required: ["issue", "why_it_matters", "suggested_test_or_decision_rule"]
        }
      }
    },
    required: ["strengths_to_steal", $field, "critique", "could_not_fault", "unresolved_issues"]
  }' >"$target/schemas/debater.schema.json"
}

judge_schema_file() {
  local target="$1"
  mkdir -p "$target/schemas"
  cat >"$target/schemas/judge.schema.json" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "converged": {"type": "boolean"},
    "converged_participants": {
      "type": "array",
      "items": {"type": "string"}
    },
    "unresolved_issues": {
      "type": "array",
      "items": {"type": "string"}
    },
    "agreements_lacking_justification": {
      "type": "array",
      "items": {"type": "string"}
    },
    "recommendation": {
      "type": "string",
      "enum": ["synthesize", "another_round"]
    },
    "focus_for_next_round": {
      "type": ["string", "null"]
    },
    "reasoning": {"type": "string"}
  },
  "required": [
    "converged",
    "converged_participants",
    "unresolved_issues",
    "agreements_lacking_justification",
    "recommendation",
    "focus_for_next_round",
    "reasoning"
  ]
}
JSON
}

write_all_schemas() {
  local target="$1"
  round0_schema_file "$target"
  debater_schema_file "$target"
  judge_schema_file "$target"
}

validate_round0_response() {
  local file="$1"
  jq -e --arg field "$CONTRACT_OUTPUT_FIELD" \
    '(.[$field] | type == "string" and length > 0)' "$file" >/dev/null
}

# Enforce the SAME contract the generated schema states, item shapes included.
#
# This is the only gate on an opencode turn: claude and codex have the schema
# enforced provider-side, opencode has no --output-schema at all. So a loose
# validator here is not defence in depth, it is the entire defence -- and the loose
# version accepted a payload the generated schema rejects with 7 errors (missing
# could_not_fault, `{"nope":1}` for a strength, `{"garbage":true}` for a critique).
# Attribution is the whole point of the N>=3 schema, so an unattributed critique
# passing validation silently destroys the judge's ability to tell who said what.
#
# Mirrors debater_schema_file: same required keys, same closed item shapes.
validate_debater_response() {
  local file="$1"
  jq -e --arg field "$CONTRACT_REVISED_FIELD" '
    def only(allowed): (keys_unsorted - allowed) == [];
    (.strengths_to_steal | type == "array") and
    (.[$field] | type == "string" and length > 0) and
    (.critique | type == "array") and
    (.could_not_fault | type == "array") and
    (.unresolved_issues | type == "array") and
    all(.strengths_to_steal[]?; (
      (type == "object") and only(["from","strength"]) and
      (.from | type == "string" and length > 0) and
      (.strength | type == "string" and length > 0)
    )) and
    all(.critique[]?; (
      (type == "object") and only(["target","finding"]) and
      (.target | type == "string" and length > 0) and
      (.finding | type == "string" and length > 0)
    )) and
    all(.could_not_fault[]?; (type == "string")) and
    all(.unresolved_issues[]?; (
      (type == "object") and
      only(["issue","why_it_matters","suggested_test_or_decision_rule"]) and
      (.issue | type == "string" and length > 0) and
      (.why_it_matters | type == "string" and length > 0) and
      (.suggested_test_or_decision_rule | type == "string" and length > 0)
    ))
  ' "$file" >/dev/null 2>&1
}

validate_judge_verdict() {
  local file="$1"
  jq -e '
    (.converged | type == "boolean") and
    (.unresolved_issues | type == "array") and
    (.agreements_lacking_justification | type == "array") and
    (.recommendation == "synthesize" or .recommendation == "another_round") and
    ((.focus_for_next_round | type == "string") or (.focus_for_next_round == null)) and
    (.reasoning | type == "string" and length > 0)
  ' "$file" >/dev/null
}
