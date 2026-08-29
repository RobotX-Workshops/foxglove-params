#!/usr/bin/env bash
#
# pre-commit hook body: validate every shipped agent-kombat roster and contract.
#
# `check-json` already proves these files parse. This proves they are *usable*:
# it runs the driver's own validator, so a roster that parses but breaks a
# cross-field rule the driver enforces (judge must be native, opencode slots need
# an agent, codex slots must pin reasoning_effort, slot ids must be unique) fails
# at commit time rather than at the start of a paid debate.
#
# Deliberately runs the real validator rather than a JSON Schema: the load-bearing
# rules here are cross-field and a schema cannot express slot-id uniqueness at all.
#
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$SCRIPT_DIR/agent-kombat.sh"

status=0

# Scratch file for driver stderr. Deliberately NOT under $SCRIPT_DIR: this hook
# runs pre-commit, and a stray .roster-check.err inside the source tree can be
# staged by a `git add -A` in another hook. The trap covers the early-exit and
# interrupt paths the old unconditional `rm -f` missed. The explicit X's in the
# template keep it portable across BSD and GNU mktemp (GNU rejects `-t` with a
# bare prefix).
ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/agent-kombat-roster-check.XXXXXX")"
cleanup_err_file() { rm -f "$ERR_FILE"; }
trap cleanup_err_file EXIT INT TERM

for roster in "$SCRIPT_DIR"/rosters/*.json; do
  name="$(basename "$roster" .json)"
  # The schema file is not a roster; it is validated separately below.
  [[ "$name" != "roster.schema" ]] || continue
  if bash "$DRIVER" --roster-check --roster-file "$roster" >/dev/null 2>"$ERR_FILE"; then
    printf 'ok: roster %s\n' "$name"
  else
    printf 'FAIL: roster %s\n' "$name" >&2
    sed -n '1,20p' "$ERR_FILE" >&2
    status=1
  fi
done

# Contracts are prompt text, so a missing key silently degrades a prompt rather
# than erroring. Check the full required key set explicitly.
for contract in "$SCRIPT_DIR"/contracts/*.json; do
  name="$(basename "$contract" .json)"
  if jq -e '
    (.id | type == "string" and length > 0) and
    (.noun | type == "string" and length > 0) and
    (.output_field | test("^[a-z][a-z0-9_]*$")) and
    (.revised_field | test("^[a-z][a-z0-9_]*$")) and
    (.final_filename | test("^[A-Za-z0-9._-]+$")) and
    (.final_label | type == "string" and length > 0) and
    (.context_mode | . == "file" or . == "none") and
    (.initial_task | type == "string" and length > 0) and
    (.debate_task | type == "string" and length > 0) and
    (.synthesis_task | type == "string" and length > 0) and
    (.round0_note | type == "string") and
    (.synthesis_note | type == "string")
  ' "$contract" >/dev/null 2>&1; then
    printf 'ok: contract %s\n' "$name"
  else
    printf 'FAIL: contract %s is missing or malforming a required key\n' "$name" >&2
    printf '      required: id noun output_field revised_field final_filename final_label\n' >&2
    printf '                context_mode(file|none) initial_task debate_task synthesis_task\n' >&2
    printf '                round0_note synthesis_note\n' >&2
    status=1
  fi
done

# The roster schema must itself be valid JSON Schema AND must actually be applied.
#
# Checking only `check_schema` left the documented behaviour unverified: nothing
# ever validated a roster INSTANCE against it, so the strict
# `additionalProperties: false` contract was decoration. A roster with a stray key
# would pass the hook while the schema claimed it could not.
if [[ -f "$SCRIPT_DIR/rosters/roster.schema.json" ]]; then
  # Distinguish "cannot check" from "checked and bad". Collapsing both into `skip`
  # made the check fail OPEN: a genuinely invalid schema reported skip and the hook
  # passed. Probe for the library first, then let a real validation failure fail.
  if .venv/bin/python -c 'import jsonschema' 2>/dev/null; then
    if .venv/bin/python - "$SCRIPT_DIR/rosters/roster.schema.json" <<'PYCHECK'
import json
import sys

from jsonschema import Draft202012Validator

with open(sys.argv[1]) as fh:
    Draft202012Validator.check_schema(json.load(fh))
PYCHECK
    then
      printf 'ok: roster.schema.json is a valid Draft 2020-12 schema\n'
      # Now apply it to every shipped roster, and to personal rosters if present.
      if .venv/bin/python - "$SCRIPT_DIR/rosters/roster.schema.json" "$SCRIPT_DIR"/rosters/*.json ./.agent-kombat/rosters/*.json <<'PYINST'
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

schema = json.loads(Path(sys.argv[1]).read_text())
validator = Draft202012Validator(schema)
bad = 0
for raw in sys.argv[2:]:
    path = Path(raw)
    if not path.is_file() or path.name == "roster.schema.json":
        continue
    errors = sorted(validator.iter_errors(json.loads(path.read_text())), key=lambda e: list(e.path))
    if errors:
        bad += 1
        print(f"FAIL: {path.name} violates roster.schema.json", file=sys.stderr)
        for err in errors[:5]:
            location = "/".join(str(p) for p in err.path) or "<root>"
            print(f"    {location}: {err.message}", file=sys.stderr)
    else:
        print(f"ok: {path.name} validates against roster.schema.json")
sys.exit(1 if bad else 0)
PYINST
      then :; else status=1; fi
    else
      printf 'FAIL: roster.schema.json is not a valid Draft 2020-12 schema\n' >&2
      status=1
    fi
  else
    # Fail rather than pass: a hook that goes green when it could not actually
    # validate reports "roster is fine" on every commit where the tooling is
    # missing, which is exactly when a bad roster slips through.
    printf 'FAIL: jsonschema not importable from .venv; roster.schema.json could not be checked\n' >&2
    status=1
  fi
fi

exit "$status"
