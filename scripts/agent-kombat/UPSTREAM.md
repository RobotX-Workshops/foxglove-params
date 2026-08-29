# Upstream provenance and divergence ledger

## Provenance

- Upstream: <https://github.com/kaushikgopal/agent-kombat>
- Default branch: **`master`** (not `main`) — remote `HEAD` points at `origin/master`.
- Pinned SHA: **`1a034dd56708532732f0734ea1073ad8a943fc5a`** (committed 2026-05-06).
- Licence: **MIT**, `Copyright (c) 2026 agent-kombat contributors`. Permissive — modification and
  redistribution are allowed; the one obligation is that the copyright notice and permission notice
  travel with the code. Pointing at upstream's `LICENSE` does not discharge that, so the notice is
  reproduced here in full:

  ```text
  MIT License

  Copyright (c) 2026 agent-kombat contributors

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
  ```

  This reproduces the standard MIT permission notice under the copyright line upstream declares.
  If upstream's `LICENSE` differs in any wording, upstream's text governs — re-check it when
  re-diffing.
- **Ported:** upstream's single bash driver `agent-kombat` (2462 lines at that pinned SHA) — the
  debate loop, round manifests, event log, resume/show, and the judge/synthesis phases. Landed here
  as `agent-kombat.sh` (the entry point) plus the `_lib/` libraries it sources — not a single file;
  see D17 and the re-diffing table below.
- **Deliberately not ported:** `skills/plan/**` (SKILL.md + 4 reference docs + `agents/openai.yaml`)
  and `skills/plan/scripts/plan_core.py` (902 lines). That subtree is a whole second product — a
  request classifier plus plan-template renderer invoked as a subprocess at ~L1181-1239 — with its
  own drift surface and no relation to running a debate. See D6.
- Upstream's own `tests/agent-kombat-smoke.sh` (623 lines) was read for reference but not ported;
  our harness targets our roster model, not upstream's fixed two-agent one.

## Re-diffing when upstream moves

The port was originally **one file**, so a change upstream stayed a mechanical diff rather than an
archaeology project. **That rationale stopped holding, and the file has since been split** along its
real seams (adapters / schemas / safety enforcement / persistence / orchestration) into
`agent-kombat.sh` (a ~500-line entry point) plus eleven libraries under `_lib/`. See D17.

- At 3,781 lines when the split began, the single file was a **6.1× outlier** in this repo — the
  next-largest tracked shell script is 620 lines, across 98 of them — against a documented "~800
  lines is a strong signal to split" that explicitly applies to *new* files.
- The mechanical-diff argument assumed line-by-line correspondence with upstream, which the 16
  divergences below had already destroyed: `plan_core.py` dropped, the round-0 prompt builders
  merged, N-way mesh replacing the hardcoded two agents, parallel in-round dispatch. Nothing was
  preserved by keeping one file.
- `scripts/_lib/gh_token.sh` and `scripts/diagrams/_lib/portable_timeout.sh` are existing
  sourced-lib precedents here.

**On `shellcheck -x` and the split.** An earlier revision of this section claimed `shellcheck -x`
"follows `source`, so the scoped lint survives" — that overstated what was actually true, and is
corrected here rather than swapped for an equally confident replacement claim. Measured by copying
the whole `scripts/agent-kombat` tree to a scratch directory with `_lib/` intact, stripping all
the entry file's `# shellcheck disable=SC2034` directives, and linting the entry file from two
different working directories:

- cwd = the script's own directory → **exit 0, no SC2034**
- cwd = anywhere else (absolute path) → **every stripped SC2034 fires**

So `# shellcheck source=_lib/<name>.sh` resolves **relative to shellcheck's working directory, not
relative to the sourcing file**. The pre-commit hook runs from the repo root against the path
`scripts/agent-kombat/agent-kombat.sh`, where `_lib/<name>.sh` does not exist from that cwd — so
under the hook the sources are unresolvable, SC1091 is emitted at *info* severity and suppressed by
`--severity=warning`, and cross-file analysis does not happen at all under the hook.

What actually keeps the lint working is therefore **one** reason, not two: the hook passes
filenames, so every file — entry point and each library — is linted **standalone**. That is also why
the entry file needs its own SC2034 directives and each library needs its own: neither can see
the other's reads (see `.pre-commit-config.yaml`'s `shellcheck-agent-kombat` hook). The
`# shellcheck source=` directives only take effect for someone running shellcheck directly from
inside `scripts/agent-kombat/` — they are not what preserves the lint under CI or the hook.

Possible follow-up, not implemented here because it is a lint-behaviour change and out of scope for
this branch: `# shellcheck source-path=SCRIPTDIR` on the entry file would make the directives
resolve regardless of cwd and restore genuine cross-file analysis.

Re-diffing means diffing upstream against the `_lib/` file that owns the corresponding
responsibility, rather than one whole-file diff:

| `_lib/*.sh` | Upstream region it corresponds to |
| --- | --- |
| `common.sh` | Output/logging/process helpers: `log_event` (~L963-977), `write_atomic` (~L303-309), `kill_process_tree` (~L189-196), the idle watchdog (~L255-267) |
| `roster.sh` | Upstream has no roster — corresponds to the hardcoded `agent1`/`agent2`/judge config (~L912-929) and judge-model derivation (`init_model_defaults` ~L618-641, `resolve_derived_judge_model` ~L681-686) that this file replaces with data (D1, D14) |
| `adapters.sh` | Per-harness dispatch, the resume/fresh call sites (~L1695-1759) |
| `contracts.sh` | Built-in contract data and validation: inline shell builtins (~L737-775), the JSON overlay loader (~L785-803), `load_contract` (~L805-814) (D4) |
| `safety.sh` | Workdir defaulting and validation: `default_workdir` (~L834-842), `-d/--workdir` handling (~L353-356) (D7) |
| `persistence.sh` | `update_config` (~L954-961), the round manifest writers (`write_round0_manifest` ~L1765-1832, `write_debate_round_manifest` ~L1834-1902) |
| `preflight.sh` | No upstream equivalent — opencode did not exist in upstream's two-harness design (D9); corresponds loosely to the `have gum`/dead-weight checks removed at D11 (~L118-125, ~L500-541, ~L2097-2103, ~L2122-2123) |
| `prompts.sh` | Round-0/debate/judge/synthesis prompt text and plan-context prep: `build_round0_prompt`/`build_round0_codex_prompt` (~L1070-1148, D5), `prepare_round0_plan_context` (~L1181-1239, D6), `write_objections_ledger` (~L1904-1916) |
| `dispatch.sh` | Owns the in-round dispatch *inside* upstream's `run_round0`/`run_debate_round` — sequential upstream: `run_claude_round0` then `run_codex_round0` (~L1946-1947), same in `run_debate_round` (~L1977-1978) — D13 replaces this with parallel dispatch |
| `orchestration.sh` | The debate loop itself: `run_round0`/`run_debate_round` (~L1946-1947, ~L1977-1978), judge replay (`run_judge_loop` ~L2003-2041), synthesis (`run_synthesis` ~L2043-2092) |
| `runmodes.sh` | `--resume` (~L2225-2241), `--show` (~L2142-2165) |

Derived from the eleven extraction commits on this branch (`git log --oneline -- scripts/agent-kombat/_lib/`),
cross-referenced against the upstream line references already pinned in the divergence ledger below
— not from fresh guesswork about upstream. From the repo root:

```bash
# tmp/ is gitignored (.gitignore:52) — the clone never enters our history
rm -rf tmp/upstream-agent-kombat
git clone https://github.com/kaushikgopal/agent-kombat.git tmp/upstream-agent-kombat
git -C tmp/upstream-agent-kombat log --oneline 1a034dd5..origin/master   # what changed since our pin
git -C tmp/upstream-agent-kombat diff 1a034dd5..origin/master -- agent-kombat
# and, to see how far a given _lib/ file has drifted from the pin -- e.g. persistence.sh, per the
# table above:
diff -u tmp/upstream-agent-kombat/agent-kombat scripts/agent-kombat/_lib/persistence.sh | less
```

Read the upstream commit range first; only then decide which hunks are worth carrying over, and
into which `_lib/` file the table says owns that responsibility. Every divergence below is
intentional — a hunk that collides with one of them is a hunk we reject on purpose, not a merge
conflict to resolve.

## Divergence ledger

| #   | Divergence | Rationale |
| --- | --- | --- |
| D1  | Per-slot model override precedence is stated and enforced as **flag > env > roster file > die** (no silent default). | Upstream's actual precedence is already flag > env > config > default, but its *judge* model is resolved out of band: `init_model_defaults` (~L618-641) runs before `parse_args` (~L2403-2404) and, when `CLAUDE_MODEL`/`AGENT_KOMBAT_CLAUDE_MODEL` is set, stamps `JUDGE_MODEL_SOURCE=derived:claude` (~L638-641). `resolve_derived_judge_model` (~L681-686) then only fires on source `default`, so `--claude-model X` with `CLAUDE_MODEL=Y` exported leaves the judge silently on `Y`. Generic env names like `CLAUDE_MODEL` (~L16-17) are exactly what a sourced `.env` sets, and this repo sources `.env` constantly. Our rule: one precedence chain per slot, no derivation, `die` on unresolved. |
| D2  | `--output-schema` is passed to `codex exec resume` too. | Upstream passes it on the fresh call (~L1695) but omits it on resume (~L1744-1751) — resume rounds are schema-*hoped*, enforced only by a post-hoc `validate_debater_response` (~L1759). codex-cli 0.145.0 accepts `--output-schema` on `resume`; there is no reason to run unenforced. |
| D3  | `reasoning_effort` is always emitted for codex slots as `-c model_reasoning_effort="..."`. | Upstream never sets it (zero occurrences in the file). `~/.codex/config.toml` here pins `model_reasoning_effort=xhigh` globally, so an unpinned slot silently inherits xhigh and its cost. Pinning per slot makes the roster the only thing that decides. |
| D4  | Built-in contracts are data files under `contracts/`, loaded by the same loader as `--contract PATH`. | Upstream has two code paths: builtins as inline shell assignments (~L737-775) and a JSON overlay loader (~L785-803), with `load_contract` (~L805-814) seeding the `artifact` builtin before overlaying JSON. Two representations of one schema plus a third copy of every default in `load_run_config` (~L2180-2192) is a drift class; one loader over data files removes it. |
| D5  | One harness-parameterised round-0 prompt builder. | Upstream keeps `build_round0_prompt` (~L1070-1108) and `build_round0_codex_prompt` (~L1110-1148) as 39-line near-copies differing in two sentences ("You are ... participant 1 of 2" and the structured-output wording). At three harnesses that becomes three copies. |
| D6  | `plan_core.py` and `skills/plan/**` dropped; replaced by a static `context/shared-context.md`. | `prepare_round0_plan_context` (~L1181-1239) shells out to a 902-line Python classifier just to render a prompt preamble, and hard-fails the run if the file is missing (~L1188). A checked-in Markdown file is auditable, diffable, and cannot fail. |
| D7  | Workdir is **enforced** under `$REPO_ROOT/tmp/`, not merely defaulted (escape hatch `AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR=1`), and `.agents/` is refused by name. | Upstream `default_workdir` (~L834-842) prefers `.agents/plans/` when it exists and otherwise writes `debate_*/` into the CWD, and `-d/--workdir` (~L353-356) is never validated. `tmp/` is gitignored here (`.gitignore:52`); `.agents/` is **not**. Defaulting is not a guarantee — enforcing is. |
| D8  | `idle_timeout_seconds` defaults to **900**. | Upstream ships the watchdog off: `AGENT_IDLE_TIMEOUT` defaults to `0` (~L33) and the timeout branch is gated on `-gt 0` (~L255). opencode offers no timeout mechanism of its own, so a wedged turn hangs the run forever. On by default, tunable per slot. |
| D9  | opencode slots run a dedicated read-only agent (`--agent kombat-debater`, required on every opencode slot); never `--auto`, never `ooy`/`OPENCODE_YOLO`. | New harness — no upstream equivalent. opencode 1.18.8 has no read-only sandbox flag, so the agent definition *is* the sandbox. `ooy` is `OPENCODE_YOLO=true`, i.e. the opposite of read-only, and has no place in a debate that must not touch the tree. |
| D10 | Per-turn payloads are `rounds/r{N}-<slot>.turn.json`; published manifests are `rounds/r{N}.manifest.json` (what `write_round_manifest` actually writes and `reconstruct_progress` globs — **not** upstream's bare `rounds/r{N}.json`). | Upstream's `build_round_summary_json` (~L1150-1168) globs `rounds/r*.json` and survives only because of its `map(select(.published == true and ...))` filter — the glob also matches per-agent structured files (`r1-agent1.json`, ~L1724) and judge attempts (`judge-1.json`, ~L1554). Unambiguous by construction beats unambiguous by filter. |
| D11 | `gum` UI, interactive intake, and `--contract-check` removed. | `gum` is not installed here, so every `have gum` branch (~L118-125, ~L500-541, ~L2097-2103, ~L2122-2123) is dead weight; the intake path (~L494-546) can only block a non-interactive caller; `--contract-check` (~L385, ~L2289-2401) burns billed calls on both harnesses and is superseded by `--check-harnesses` / `--roster-check`, which are free. |
| D12 | Default `rounds` is **2**, not 3. | Upstream `ROUNDS=3` (~L22). Cost: rounds are the multiplier on every slot. The judge replay round (`run_judge_loop` ~L2003-2041) still takes a run to 3 when the judge asks for it, so depth is earned rather than paid for up front. |
| D13 | Slots within a round dispatch **in parallel**; each writes `rounds/r{N}-<slot>.events.jsonl`, merged into `events.jsonl` at the round barrier. | Upstream is strictly sequential — `run_round0` calls `run_claude_round0` then `run_codex_round0` (~L1946-1947), same in `run_debate_round` (~L1977-1978) — so wall-clock is the sum of the slowest models, and N debaters would make that worse. The merge exists for two distinct reasons. (a) **Corruption:** the parent poll loop is single-threaded, so parent-side logging alone could safely share one file — but each adapter **child** also emits its own events (the `fenced_json` re-ask loop runs inside the child), and concurrent appends to one file interleave **mid-line** (upstream's `log_event` ~L963-977 is a bare `>>`, and macOS ships no `flock(1)` to serialise them). Each slot therefore owns its file, written by the child while it lives and by the parent only after it is dead. (b) **Determinism:** parent-side completion events would otherwise be ordered by whichever slot finished first. Merging in roster-then-timestamp order restores a stable sequence, which is what lets `smoke.sh` assert on the event sequence at all — it verifies two identical runs produce a byte-identical `(event, slot)` sequence. |
| D14 | N-way full mesh; every participant is a roster slot with an **anonymised** label ("Participant A"); judge and synthesizer are first-class slots. | Upstream hardcodes `agent1: {name: "claude"}`, `agent2: {name: "codex"}`, `judge: {name: "claude"}` (~L912-929) and defaults the judge model to the Claude debater's (~L681-686), while its own judge prompt opens "You are an independent judge. You did not participate in the debate." (~L1246). Sharing a harness *and* a model with a debater is not independence. Hence: judge is a slot you must configure, and the driver warns when `judge.{harness,model}` matches any debater's pair. Labels are anonymous so a debater cannot defer to a brand name. |
| D15 | A mandatory isolated-subagent grounding triage of `plan-final.md` before the output is trusted. | Repo rule, inherited from `second-opinion` / `glm-delegate`: model output is guilty until proven innocent. Upstream has no equivalent — `run_synthesis` (~L2043-2092) writes the final Markdown and exits `ok`. A synthesised plan that cites files or APIs that do not exist is the failure mode this catches. |
| D19 | Review-driven correctness fixes on top of the port: judge attempts are reused on `--resume` when a valid `rounds/judge-N.turn.json` already exists; round manifests go through `write_atomic`; `validate_judge_verdict` also requires `converged_participants`; an unknown `context_mode` dies instead of silently producing no shared-context file; `check_flag` matches whole flag tokens; the opencode canary forwards `--variant`; the symlink walk terminates at the unresolved `tmp` path; `${SLOT_ORDER[@]}`, `${!MODEL_OVERRIDE[@]}` and the heartbeat `waiting` array are guarded for empty expansion; judge and synthesis prompts frame embedded participant artifacts as untrusted content; the roster-check hook fails when it cannot validate; fixtures no longer name a harness in their plan headings. | Found by adversarial review of the vendoring PR. Three carry money or correctness weight rather than tidiness: the judge was re-billed on every resume that died after the verdict but before synthesis; a non-atomic manifest write reintroduces exactly the half-written-state class `write_atomic` exists to prevent; and `grep -q -- --json` also matched `--json-schema`, so a renamed flag would have reported green. The empty-array guards make the documented "bash >= 4.0 is enough because empty-array expansions are guarded" claim in SKILL.md true, which it was not at three sites. |
| D18 | `file_mtime_epoch` probes GNU `stat -c` before BSD `stat -f` and validates the result; `sha256_file` falls back to `sha256sum`; the "not gitignored" die message recommends `tmp` rather than `tmp/`. | Three defects found on vendoring. `stat -f` on GNU coreutils means `--file-system`: it prints a filesystem report to stdout *and* exits non-zero, so the original BSD-first `\|\|` chain concatenated that report with the real epoch — the exact trap `file_size_bytes` directly above already documents and avoids. `shasum` is not universal and a missing digest silently weakens the manifest. The die message was self-defeating: `git check-ignore -q tmp` runs before the workdir exists, and a trailing-slash pattern only matches an existing directory, so an operator following the message hit the same `die` forever. |
| D17 | The port is split into `agent-kombat.sh` (a ~500-line entry point) plus eleven libraries under `_lib/`, each sourced unconditionally at file top level, rather than kept as upstream's single file. | Originally kept as one file so a change upstream stayed a mechanical diff; that rationale stopped holding. At 3,781 lines the single file was a **6.1×** outlier against the next-largest tracked shell script in this repo (620 lines, across 98 of them), against this repo's own "~800 lines is a strong signal to split" guidance for *new* files. By the time of the split the port had already diverged from upstream structurally in 16 recorded ways (D1-D16), so no line-by-line correspondence with upstream was being preserved by keeping one file. See "Re-diffing when upstream moves" above for the per-`_lib/` mapping. |

## Kept deliberately — do not simplify away

- **`run_with_heartbeat` (~L198-293) + `kill_process_tree` (~L189-196) + the idle watchdog (~L255-267)** — the only thing standing between a wedged harness and an unbounded hang; `pkill -P` is needed because the CLIs spawn children that outlive a plain `kill`.
- **`write_atomic` (~L303-309) and `update_config`'s mktemp-and-mv (~L954-961)** — `config.json` is the resume contract; a half-written one is an unresumable run. (Note: upstream *defines* `write_atomic` and never calls it — the port actually wires it up.)
- **`events.jsonl` + `log_event` (~L963-977)** — the append-only causal record; it is what the smoke test asserts against and what makes a failed run diagnosable after the fact.
- **`--resume` (~L2225-2241) and `--show` (~L2142-2165)** — a debate is expensive; resuming from the last published round instead of re-running it is the whole point of durable state.
- **Round manifests + sha256 (`write_round0_manifest` ~L1765-1832, `write_debate_round_manifest` ~L1834-1902)** — `frozen_inputs` (~L1871-1874) proves each debater argued against the exact bytes we published, not a later revision.
- **The objections ledger (`write_objections_ledger` ~L1904-1916)** — carries unresolved issues forward so the judge sees what was *not* settled, not just the latest polished artifact.
- **The session-id assertions (~L1530, ~L1593, ~L1654, ~L1757, ~L2085)** — a resume that silently starts a fresh session yields a debater with no memory of its own plan; without the assertion that failure is invisible.
- **`expand_prompt_file_refs` (~L582-616)** — `@file` expansion, hardened here: absolute paths and `..` are rejected and total expansion is capped at 256 KB (upstream checks only for `-*` and `*://*` prefixes, ~L591-596, so `@/etc/passwd` or `@../../secrets` expands straight into a prompt sent to three vendors).

---

## opencode agent discovery — RESOLVED: the listing is flaky, the dispatch is not

**Superseded.** An earlier revision of this section blamed, in turn, project-level
vs global install location, repo content under `.claude/`, and a non-empty
`sandboxes` array on this repo's `project` row in `~/.local/share/opencode/opencode.db`.
**All three were artefacts of a non-deterministic measurement and are retracted.**

The actual behaviour, measured 2026-07-30 on opencode 1.18.8:

```text
# eight consecutive `opencode agent list`, ZERO file changes between them:
0 1 0 0 0 0 1 0        # kombat-debater present ~1 run in 4

# three consecutive real dispatches on the same tree:
opencode run "Reply with exactly: ok" --agent kombat-debater -m zai/glm-5.2-fast
  -> honoured the agent 3/3; no "Falling back" line; tree unmodified
```

So `opencode agent list` races custom-agent registration and is unsafe to gate on,
while `opencode run --agent` is reliable. Every bisect built on the listing —
removing `.claude/`, `.claude/skills/`, the agent file, the DB row — produced
whichever answer the coin flip gave, which is why each looked causal in turn.

**Lesson worth keeping:** test the instrument before trusting a bisect. Eight
repeats of the *unchanged* baseline would have caught this before any conclusion
was drawn, and cost seconds.

**Consequences for this port:**

* `preflight_opencode_agents` does not consult the listing at all. It **proves** the
  agent with a canary dispatch (`opencode run "Reply with exactly: ok" --agent <a>`)
  on the slot's own model, and **dies** if it does not resolve. That is
  the only pre-debate check that observes the same resolution path the debate takes.
  Escape hatch: `AGENT_KOMBAT_SKIP_OPENCODE_CANARY=1`, which warns loudly.
* Warning-and-continuing was the shipped behaviour and was wrong: since `--agent`
  fails open, "warn" means the write-capable `build` agent has *already run* by the
  time anyone reads the warning. Both remaining guards --- per-turn
  `not found. Falling back` detection in `adapter_opencode`, and
  `assert_tree_untouched` per round --- are likewise post-hoc, so neither can
  substitute for refusing up front. `smoke.sh` asserts the refusal directly by
  making the fake reproduce opencode's fail-open behaviour.
* `DEFAULT_ROSTER="trio-debate"` — all three harnesses. It was briefly `pair` while
  the listing was believed to be authoritative.

`--agent` still fails **open** in opencode itself (an unresolvable name falls back to
the write-capable `build` agent and exits 0), so the per-dispatch check is not
optional. That part of the earlier analysis stands.

### Containment probes (2026-07-31, opencode 1.18.8, zai/glm-5.2-fast)

The read-only agent's guarantees were asserted from its config, never exercised.
They are now probed; details and the honest limits are in
[.opencode/agent/kombat-debater.md](../../.opencode/agent/kombat-debater.md)
§ "What is actually verified, and what is not".

| Probe | Result |
|---|---|
| create a file under `tmp/` | refused, no file |
| run `echo hi` | refused, no execution |
| read a `*.env` **decoy** (fabricated content) | tool call **DENIED**, matched `read:*.env→deny` |
| read a plain `tmp/*.txt` control | succeeded — grounding intact |

Re-probed 2026-08-21 against `deepseek/deepseek-v4-pro`: the `*.env` decoy read was
**DENIED at the permission layer** (the tool return listed the resolved rule chain,
inherited `ask` entries first and this agent's `deny` entries last) and the plain
`tmp/*.txt` control still succeeded. Containment is enforced by opencode, not by the
model — but note that DeepSeek's *first* answer declined on its own secret-handling
judgement without ever calling the tool, which proves nothing. A refusal is not
evidence of enforcement; the prompt has to demand the attempt.

The write/bash probes prove outcome only: neither turn attempted a tool call, so
they cannot separate the `tools:` block stripping the tool from the model merely
complying with its prompt. The `.env` denial is the one mechanically demonstrated
enforcement, and it also printed opencode's resolved rule chain, confirming that
this agent's entries merge **last** and so override the inherited `*.env → ask`.
That is why the `read:` key is a pattern map and not a bare `allow`.

### opencode slot moved from GLM to DeepSeek (2026-08-21)

The `opencode` slot in every debate roster (`trio-debate`, `trio`, `duo`) now runs
`deepseek/deepseek-v4-pro` instead of `zai/glm-5.2`. `rosters/glm-only.json` became
`rosters/deepseek-only.json` and is the one exception: it deliberately pairs
`deepseek-v4-flash` against `deepseek-v4-pro`, because that preset exists to
exercise the `fenced_json` path with two different models rather than to decide
anything. Slot id `glm` → `deepseek`, which renames the artifact paths
(`rounds/r0-deepseek.turn.json`, `plan-deepseek.md`) and the override keys
(`--model deepseek=...`, `AGENT_KOMBAT_MODEL_DEEPSEEK`).

**The swap was not data-only.** `preflight_opencode_agents` derived a cheap canary
model by string-munging the slot's id — `${model%%-fast}-fast` — which was only ever
correct because `zai/glm-5.2-fast` happened to exist. DeepSeek's cheap tier is
`deepseek/deepseek-v4-flash`, so the rewrite produced `deepseek/deepseek-v4-pro-fast`
and the provider answered with a generic `Unexpected server error`. The canary would
have refused every DeepSeek roster with a message blaming the read-only *agent* — a
diagnostic pointing at the wrong subsystem entirely. The canary now dispatches the
slot's model unmodified, which also strengthens the check: the model id itself is
proven to resolve, not just the agent.

**Lesson worth keeping:** a "cheapest sibling" model id is a per-provider naming
convention, not a portable transform. Do not derive one model id from another.

The anonymity guards in `smoke.sh` and the three fake harnesses matched the literal
string `zai/glm`, so they would have gone on passing while guarding nothing. They now
match `deepseek/`. A leak guard keyed to a model id needs updating whenever the
roster's models change.

### D16 -- read-loop guard (mid-turn hard stop + post-turn warning)

New feature, no upstream equivalent. Two tiers: after each turn the driver counts
read-like tool calls in the raw output and warns when they exceed a configurable
budget (`MAX_READS_PER_TURN`), and *during* a turn the watchdog hard-kills any
still-running slot that exceeds a higher hard limit (`HARD_READ_LIMIT`).

The warn tier counts aggregate across re-asks and api-error retries within a turn,
so a turn that only breaches the budget in aggregate is still flagged; the turn is
not failed -- it may still produce valid JSON. The hard tier exists because the
warn tier is evaluated post-hoc: a read loop streams tool calls continuously, so
the only thing that stopped it was the wall-clock budget -- `idle_timeout * 2`,
40 minutes for the deepseek slot -- during which the loop burned ~500 reads and
hundreds of thousands of tokens. Counting reads on the partial `.raw` (opencode
streams `tool_use` events progressively) and killing at the hard limit stops the
same loop in seconds. The kill rides the heartbeat cadence in `par_run`
(`_lib/dispatch.sh`) so the growing `.raw` is grepped once per heartbeat rather
than every poll, and logs an `agent.read_limit.killed` event with the same
`status=124` the wall-clock kill uses. The thresholds, env overrides, event names,
and the helpers that drive both tiers (`count_read_tool_calls`,
`accumulate_read_calls`, `warn_read_heavy_turn`) live in `_lib/adapters.sh` and
`_lib/dispatch.sh` and are not repeated here so this summary cannot drift out of
sync with the implementation.

The guard fires on both turn-completion paths: the success branch in
`harness_send` and the wall-clock timeout-kill branch in `par_run`. The timeout
path matters more -- a stuck read-loop that gets killed is the canonical case,
and without the call there it would surface only as an `agent.process.timeout`
with no read-count diagnostic.

Coverage is effective for opencode and codex (streaming JSONL event traces with
tool-call events). claude is a structural no-op: its adapter uses
`--output-format json`, a single result object with no tool-call trace, so the
regex matches nothing in a real claude `.raw`. Closing that gap requires
switching the claude adapter to `stream-json` (follow-up). The opencode/codex
event shapes are inferred from the adapters' event handling, not yet confirmed
against a captured tool-call event.
