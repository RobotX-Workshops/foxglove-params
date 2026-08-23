---
name: agent-kombat
description: Run an adversarial multi-model PLAN DEBATE (Claude vs Codex vs DeepSeek-via-opencode) through scripts/agent-kombat/agent-kombat.sh, then ground the winning plan in an isolated subagent before anyone acts on it. PLANNING-ONLY and EXPENSIVE — 8-15 model calls depending on roster, roughly $6-15 and 15-30 minutes of wall clock per run. Use when the user says "agent kombat", "debate this plan", "let the models fight it out", "adversarial plan review", "have Claude and Codex argue about this design", or when a decision is genuinely expensive to undo (public API shape, schema migration, cross-service contract, service split, event envelope change). Do NOT trigger for cheap or obvious changes (.gitignore edits, renames, one-file diffs, doc tweaks, anything a single subagent settles in one pass), and do NOT trigger at execution time — debating work that is already planned is tokenmaxxing. Companion to `second-opinion` (adversarial review of an existing diff/spec — far cheaper, prefer it when the artifact already exists) and `glm-delegate` (one cheap delegated task); this is the expensive multi-round option and inherits their non-negotiable isolated-subagent triage of external-model output.
argument-hint: "<requirement or @file> [--roster <name>] [-r N] [--no-judge]"
allowed-tools: [Read, Write, Glob, Grep, Bash, Agent, AskUserQuestion]
---

# agent-kombat

Wrapper for [scripts/agent-kombat/agent-kombat.sh](../../../scripts/agent-kombat/agent-kombat.sh):
an adversarial **plan debate** across heterogeneous harnesses (`claude`,
`codex`, `opencode`). Each participant writes an independent plan, revises it
after reading the others', then a judge picks or merges and flags what is still
unresolved.

The point is not "more compute" — it's that **different model families fail
differently**. Claude's confidently-invented file path is not GPT's
over-abstracted layering is not DeepSeek's dropped constraint; single-model plan
review shares the reviewer's blind spots with the author. Cross-family
disagreement is the signal, the artifacts are just receipts. Participants are
**anonymous by construction** — every slot's `label` is `Participant A`-style,
never a model name, so nobody defers to a brand.

## Prerequisites

Three separate vendor CLIs, and **two of them cannot be installed from this repo**.
Run the free checks at the bottom of this section before assuming a machine is ready.

| Requirement | How to get it | If missing |
|---|---|---|
| **`bash` >= 4.0** | `brew install bash`, and make sure its dir precedes `/bin` in `PATH` | The driver refuses immediately with a version message. macOS ships bash **3.2** at `/bin/bash`. 4.0 is enough because `wait -n` (4.3+) is deliberately not used and empty-array expansions are guarded |
| **`jq`** and **`shasum`** | `brew install jq` (shasum ships with macOS/perl) | Refused at preflight |
| **`claude`** CLI, authenticated | already present if you are reading this in Claude Code | Only rosters with a `claude` slot are affected |
| **`codex`** CLI, authenticated | **no `make` target exists here** — install and `codex login` yourself | Rosters with a `codex` slot (`pair`, `trio`, `trio-debate`) will not run |
| **`opencode`** + a DeepSeek key | `make install-glm-tools` installs the CLI (it configures Z.ai, which the kombat rosters no longer use); authenticate DeepSeek separately with `opencode auth login` → DeepSeek | Rosters with an `opencode` slot (`trio-debate`, `trio`, `duo`, `deepseek-only`) will not run |
| **`.opencode/agent/kombat-debater.md`** loads | tracked in the repo; nothing to install | Proven by a canary dispatch at preflight; the run is refused if it does not resolve. See the flaky-listing note under Rosters — the listing is not trusted |
| **`shellcheck`** | `brew install shellcheck` | Only needed to *edit* `scripts/agent-kombat/*.sh`; a scoped pre-commit hook runs it |
| **`gum`** | not required | Upstream's UI is not ported |

Only the harnesses your chosen roster actually names are checked, so a machine
without `codex` can still run `--roster duo`, and one without `opencode` can run
`--roster pair`.

Verify a machine, all free, no model calls:

```bash
make kombat-roster-check                     # every preset parses and validates
bash scripts/agent-kombat/agent-kombat.sh --check-harnesses   # each CLI still has the flags we use
make kombat-smoke                            # full loop against fake harnesses
make kombat-dry-run REQ="anything"           # writes every prompt, calls nothing
```

`--check-harnesses` is the one to run on a new machine: it greps each CLI's own
`--help` for every flag the adapters depend on, so a vendor renaming a flag is a
clear message rather than a mid-debate failure.

## Cost — read before you type

| Knob | Reality |
|------|---------|
| Model calls | **11 nominal, 15 worst case** for `trio-debate` at `-r 2`; **8-11** for `pair`. The driver prints both at startup from `N*(1+rounds+max_extra) + max_extra + 2` — a judge replay runs a full extra round *and* another judge call, so both terms grow. Trust the driver's number, not this table. |
| Money | roughly **$6-15** per run at that shape |
| Wall clock | **15-30 min** |

**A failed run still costs money.** Each participant is billed for what it consumed
before anything went wrong — an aborted `claude` turn on a large prompt has been
observed billing **$0.53** in cache-creation tokens alone while returning no usable
output. Run the free checks above first; they exist so a broken machine fails for
nothing instead of for dollars.

**Never run it speculatively** or "to see what it says". If you're unsure the
decision is expensive enough, it isn't — do the cheap thing and keep the money.

## When to use / when NOT to use

**Use** — anything where **being wrong is expensive to undo** (data migrated,
contract published, partners integrated): public API / RPC surface, event-envelope
or CloudEvents contract changes; ClickHouse / Postgres migrations, especially with
a down-chain; architecture calls (service split, ownership boundary,
sync-vs-async, retry/DLQ strategy); cross-service contracts two teams agree once
and live with.

**Don't** — `.gitignore`, renames, formatting, doc edits, one-file changes. Not
**at execution time**: once a plan is accepted, implement it; re-debating settled
work is pure tokenmaxxing. Artifact already exists and wants critique →
`second-opinion`. One cheap delegated pass suffices → `glm-delegate`. And when
the blocker is missing *information* rather than missing judgement, three models
guessing is worse than one `grep`.

## Rosters

A roster names the slots: `debaters` (>= 2), `judge`, optional `synthesizer`
(defaults to the judge). Presets live in
[scripts/agent-kombat/rosters/](../../../scripts/agent-kombat/rosters/) (`ls` it
for the current set; the shape is in `rosters/roster.schema.json`, and each
preset's own `description` field states its trade-off — read it before running):

| Preset | Shape |
|--------|-------|
| `trio-debate` | **built-in default.** 3 debaters (Claude Opus, Codex sol, opencode DeepSeek V4 Pro) + Claude Opus judge. Judge shares harness+model with debater `opus` → session independence, *not* model independence |
| `trio` | Claude Opus vs opencode DeepSeek V4 Pro, **Codex judge** — nobody shares a vendor with the judge. Prefer when the *verdict* is the deliverable |
| `duo` | **two models total:** Claude Opus vs opencode DeepSeek V4 Pro, with Opus also judging in a fresh session. Cheapest useful preset — but it **does** contain an opencode slot, so it needs a working `opencode` + DeepSeek key; `pair` is the one that needs neither. Judge is session- but not model-independent |
| `pair` | Claude Opus vs Codex sol, no opencode. Both enforce their schema natively, so there is no fenced-JSON extraction and nothing to re-ask — the most reliable preset, and the one to use when the opencode agent is not registered (see below) |
| `deepseek-only` | cheap plumbing test of the `fenced_json` path (DeepSeek V4 Flash vs V4 Pro). Not a real debate — never decide anything with it |

### If an opencode slot warns about the read-only agent

`opencode agent list` is **unreliable** — the same unchanged tree lists
`kombat-debater` on roughly one invocation in four (measured: `0 1 0 0 0 0 1 0`).
`opencode run --agent` is **not** unreliable: 3/3 dispatches honoured the agent on
a tree whose listing was mostly failing. So the listing is not consulted at all.

Preflight instead **proves** the agent by dispatching it — a one-word canary turn on
the slot's own model, which exercises exactly the resolution path the debate will
use. It used to rewrite the id to a cheaper sibling (`${model%%-fast}-fast`), which
only worked while the slot was GLM; DeepSeek's cheap tier is `-flash`, so that
rewrite produced a nonexistent model and refused a valid roster. If it does not resolve, the run is **refused** before any
debate dispatch. The alternatives were both unacceptable: gating on the listing
refuses ~75% of valid runs, and warning-then-continuing means the write-capable
`build` agent has already run by the time anything notices.

Per-turn `not found. Falling back` detection and `assert_tree_untouched` remain, but
they are backstops — both are post-hoc. If the canary fails, check that
`.opencode/agent/kombat-debater.md` exists and parses:

```sh
opencode run 'hi' --agent kombat-debater -m deepseek/deepseek-v4-pro --format json 2>&1 | head
```

`AGENT_KOMBAT_SKIP_OPENCODE_CANARY=1` skips the proof. It warns loudly and you own
the consequence; there is no reason to set it except an outage in the canary model.

`--roster pair` needs no opencode at all, and stays the fallback for a machine
where opencode cannot be made to work.

### Selection precedence

```text
selection:      --roster-file <path> > --roster <name> > $AGENT_KOMBAT_ROSTER > built-in "trio-debate"
per-slot model: --model <slot_id>=<model> > $AGENT_KOMBAT_MODEL_<SLOT_ID> > roster file > die
```

`--roster <name>` searches `./.agent-kombat/rosters/<name>.json` (personal,
gitignored) **then** `scripts/agent-kombat/rosters/<name>.json` (repo preset),
so a personal roster shadows a preset of the same name. Never guess a slot id
for `--model` — confirm it with `--roster-check` first (an unknown slot is a hard
error).

### Constraints the driver enforces

- `judge.structured_output` must be `native`. The judge's `recommendation` enum
  *is* control flow, so a parse miss there is unrecoverable — unlike a debater
  miss, which a re-ask recovers. Override only via `--allow-unstructured-judge`.
- **`opencode` has no structured output at all** (no `--output-schema` in
  1.18.8), so an opencode slot is `fenced_json` and can never judge by default.
- Every `opencode` slot must set `agent` — always `kombat-debater`
  ([.opencode/agent/kombat-debater.md](../../../.opencode/agent/kombat-debater.md)).
  opencode has no read-only sandbox flag, so that agent's permission set is what
  keeps an opencode debater out of your working tree — **and it fails open**: an
  unresolvable `--agent` name falls back to `build` (bash and writes allowed) with
  exit 0. The driver therefore **refuses to start** unless a canary dispatch proves
  the agent resolves, and treats a `not found. Falling back` line mid-run as a hard
  turn failure. Do not weaken either guard.
- Every `codex` slot must set `reasoning_effort`: `~/.codex/config.toml` pins
  `model_reasoning_effort=xhigh` **globally**, so an unpinned slot bills at xhigh.
- Slot ids unique across debaters + judge + synthesizer. A judge whose
  `{harness, model}` matches a debater only **warns** — `pair`, `duo` and
  `trio-debate` all trip it deliberately. Understand the warning rather than ignoring it: that
  judge has session independence, not model independence, so it may
  systematically favour its twin. When the *verdict* is the deliverable, use `trio`.

### Worked example — 2 models, model-independent judge

`trio` = debaters `opus` (claude) + `deepseek` (opencode), judge `judge` (codex):

```bash
bash scripts/agent-kombat/agent-kombat.sh --roster trio -r 2 \
  "@docs/architecture/ene-99-dlq-strategy-spike.md — settle the DLQ replay contract"
```

### Worked example — 3 models, with a per-slot model override

`trio-debate` = debaters `opus`, `sol`, `deepseek` + judge `judge`. Override one
slot without editing the preset (equivalently
`AGENT_KOMBAT_MODEL_DEEPSEEK=deepseek/deepseek-v4-flash`):

```bash
bash scripts/agent-kombat/agent-kombat.sh --roster trio-debate -r 2 \
  --model deepseek=deepseek/deepseek-v4-flash \
  "plan the property-store tenant-scoping migration, including the down-chain"
```

Need a variation the presets don't cover? Copy a preset to
`./.agent-kombat/rosters/<name>.json` (personal, gitignored) and edit there —
never mutate a shipped preset for a one-off run. Valid opencode models (verified
by dispatch on this machine): `deepseek/deepseek-v4-pro`,
`deepseek/deepseek-v4-flash`. There is **no** `-fast` sibling — do not assume one.
`--variant` is real reasoning effort here. The driver refuses a value outside
`none|minimal|low|medium|high|xhigh|max`, because opencode silently ignores an
unknown one rather than erroring. It does **not** check the per-model subset, and
no test pins it — as of 2026-08-21 models.dev reports `v4-pro` declaring
`low|medium|high` and `v4-flash` `high|max`, but that shifts with each release, so
confirm against the model rather than trusting this line.

## Run it in cost order — free checks first

```bash
bash scripts/agent-kombat/agent-kombat.sh --roster-check --roster trio-debate  # free: roster valid, ids printed
bash scripts/agent-kombat/agent-kombat.sh --check-harnesses                    # free: claude/codex/opencode callable
bash scripts/agent-kombat/agent-kombat.sh --dry-run -r 2 "<requirement>"       # free: full run plan, 0 model calls
bash scripts/agent-kombat/agent-kombat.sh -r 2 "<requirement>"                 # the expensive one
```

Dispatch the real run with `run_in_background: true` and poll — it outlives the
10-minute foreground `Bash` timeout, same rule as `glm-delegate`. Exit codes:
`0` ok · `2` unresolved / validation refusal (read the output, don't retry
blindly) · other non-zero = setup error. Interrupted → `--resume <workdir>`;
finished → `--show <workdir>`. `--contract plan|artifact|PATH` swaps the schema
and prompts when the deliverable is not plan-shaped; `--dry-run` prints the
resolved contract and the final filename, so read that rather than assuming.

## Reading the output

Run dir: `tmp/agent-kombat/debate_YYYYMMDD_HHMMSS/`.

| Path | What it is |
|------|-----------|
| `requirement.txt` | expanded requirement, `@file` refs inlined — check first when a debate went sideways |
| `config.json` | resolved roster + flags, i.e. what actually ran |
| `events.jsonl` | merged timeline; per-slot `rounds/r{N}-<slot>.events.jsonl` merge in at each round barrier |
| `rounds/r{N}-<slot>.prompt.txt` / `.turn.json` | exactly what a slot was asked / its structured answer |
| `rounds/r{N}.manifest.json` | published round manifest (the barrier's output). The `.manifest.json` suffix *is* divergence D10 — it keeps the resume glob unambiguous by construction |
| `plan-<slot>.md` | each participant's own final plan |
| `judge-verdict.json` | `recommendation` + **`unresolved_issues`** |
| `plan-final.md` | **the deliverable** |
| `triage.md` | the grounding verdict (below) — a run without this is not done |

`plan-final.md` is what people read. **`unresolved_issues` in
`judge-verdict.json` is what people skip, and it's the highest-value field in
the run**: the things multiple models could not agree on, i.e. exactly the
decisions that need a human. Quote it verbatim to the user; never let a summary
swallow it.

## MANDATORY final step — ground the plan (upstream has no such step)

`plan-final.md` is **external model output**; most of it was written by models
with no vetting for this repo. Both `second-opinion` and `glm-delegate` make
isolated-subagent triage of exactly this category non-optional — output is guilty
until proven innocent. Same rule here, no exemption for "a judge already reviewed
it": the judge is external output too. So once `plan-final.md` exists, dispatch
**exactly one** isolated native `Agent` (clean context, read access to the real
repo) to **ground** it:

- Does every cited file / path / symbol exist? (`Glob`/`Grep`, not memory.)
- Does each claimed convention actually say that? Open `AGENTS.md`, `CLAUDE.md`,
  `docs/`, the migration, the contract — quote the line.
- Are the commands, make targets, flags and env vars real? Confirm a make target by
  reading the `Makefile` or `make -n`, **never by running it.** Tell the grounding agent
  so explicitly: no mutating commands, and no `make` target invoked for real.

**The run dir is destroyable, and once was destroyed mid-triage.** A `make kombat-clean`
+ `make kombat-smoke` cycle on this branch wiped `tmp/agent-kombat/` while a grounding
pass was still running — taking `plan-final.md`, `judge-verdict.json`, both participant
plans, `requirement.txt`, `rounds/` and the in-progress `triage.md` with it. The
artifacts are gitignored, so the loss was total and a re-run costs the full $6-15.
`kombat-clean` now spares real debates unless `ALL=1`, but two things follow anyway:
anything that must outlive the session gets hand-copied out of `tmp/` **before** you
finish, and a long-running grounding agent should be treated as holding a lock on the
run dir — do not run debate-adjacent make targets while one is in flight.
- Does any step contradict a repo hard rule (test-before-push, migration
  down-chain, generated-file ownership, an ADR)?

Verdict → `triage.md` in the run dir: **accept** (grounded, safe to implement) /
**reject** (cites things that don't exist — name them) / **needs-user-decision**
(legitimate but a judgement call, usually the `unresolved_issues`). Never hand a
**reject** or **needs-user-decision** plan to an implementer as if accepted.

## Hard rules

1. **Nothing from `tmp/` is ever committed** — the run dir is gitignored
   ([.gitignore](../../../.gitignore): `tmp/`) and stays that way. Worth
   keeping? Hand-copy the *reviewed* content into a real doc or Linear ticket.
   The driver refuses any workdir outside `$REPO_ROOT/tmp/` (escape hatch
   `AGENT_KOMBAT_ALLOW_UNSAFE_WORKDIR=1`) and refuses `.agents/` by name —
   `.agents/` is **not** gitignored here, and was upstream's default workdir.
2. **Never point a debate at secrets.** `codex -s read-only` blocks *writes*,
   not *reads*: it will happily read `.env` and ship it to OpenAI — the same
   exposure `second-opinion` already carries. No `.env`, no key material, no
   customer data, no `@` reference that transitively pulls one in.
3. **Never `ooy` / `OPENCODE_YOLO=true` / `--auto` for a participant.**
   `--auto` auto-approves every permission not *explicitly* denied, defeating
   the read-only guarantee `kombat-debater` exists to provide. `glm-delegate`
   uses `OPENCODE_YOLO` deliberately; a debate participant must not.
4. **Planning only.** Claude slots run print-mode with tools off, codex slots
   read-only, opencode slots behind `kombat-debater`. The debate never edits.

## Common mistakes

| Mistake / red flag | Fix |
|--------------------|-----|
| Running it on a small or obvious change | Don't — ~$6-15 and 20 min for a rename is indefensible |
| Running it during implementation | Planning only; re-debating settled work is tokenmaxxing |
| Skipping `--roster-check` / `--dry-run` | Both free; a bad roster fails *after* you've paid for round 0 |
| Guessing a slot id for `--model` | Driver dies on unknown slots — take ids from `--roster-check` |
| `opencode` slot without `agent: kombat-debater` | Driver refuses; without it the opencode debater can write to your tree |
| `codex` slot without `reasoning_effort` | Inherits global `xhigh` and quietly costs multiples |
| Quoting a `trio-debate` verdict as impartial | Its judge is Opus judging an Opus debater — use `trio` when the verdict is the point |
| Editing a shipped preset for a one-off | Copy it to `./.agent-kombat/rosters/` (gitignored) or use `--model` |
| Deciding anything with `deepseek-only` | It's a cheap plumbing test of the `fenced_json` path, not a debate |
| Treating `plan-final.md` as ground truth | External model output; the `triage.md` grounding pass is mandatory |
| Reporting the plan without `unresolved_issues` | That's the human-decision list — quote it verbatim |
| Committing the run dir, or `--workdir .agents/…` | `tmp/` only; `.agents/` is tracked and refused by name |
| Foreground `Bash` for the real run | Background + poll; a real run outlives the 10-min timeout |

## See also

- [scripts/agent-kombat/agent-kombat.sh](../../../scripts/agent-kombat/agent-kombat.sh) — the driver, single source of truth for flags
- [.opencode/agent/kombat-debater.md](../../../.opencode/agent/kombat-debater.md) — the read-only opencode participant
- `second-opinion` (not installed in this repo) — cheaper external review of an existing artifact
- `glm-delegate` (not installed in this repo) — single delegated task, same triage doctrine
