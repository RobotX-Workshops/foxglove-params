# Shared Context — Implementation Planning in `ENE_core`

`ENE_core` is GALVANY's energy-intelligence monorepo: Go services under `services/` (`control-api`,
`property-store`, `provisioning`, `hems`, `command-executor`, `supplier-proxy`, `supplier-poller`,
`supplier-webhook`, `panasonic-oauth`, `panasonic-callback`, `savings-engine`, `watchdog`,
`fox-event-bridge`, `normalisation`, …), Benthos stream configs
(`services/normalisation/transforms/*.yaml`), ClickHouse + Postgres migrations
(`services/<svc>/migrations/`), Terraform (`terraform/`), a Python test suite (`tests/`) and shared
Python helpers (`lib/`). Supplier wire contracts: `suppliers/schemas/`. Data contract:
`contract/data-catalog.yml`. Multi-module Go workspace via `go.work`; task entrypoints in `Makefile`.

## Where the authoritative conventions live — consult, don't guess

- `AGENTS.md` (repo root, ~1850 lines) — the master rulebook: commit/PR format, migration policy,
  error handling, HTTP status policy, fail-loud, identifier naming, timestamps, pre-push checklist,
  CI-debugging and PR-review-bot procedures. When two docs disagree, this one wins.
- `CODING_STANDARDS.md` (repo root) — Python/test-suite standards: ruff + mypy strict, 120 cols,
  double quotes, `pytest.approx` for floats, test names `test_<what>_<condition>_<expected_result>`, lazy
  `%s` logging (never f-strings in log calls), SQL style (UPPERCASE keywords, `snake_case`,
  `DateTime64(3, 'UTC')`, `LowCardinality(String)`, `COMMENT` on every ClickHouse table).
- `services/AGENTS.md`, `services/CODING_STANDARDS.md` — generated copies; edit the root and re-sync.
- `docs/adr/` — 20 accepted ADRs (`0001`–`0020`) + `README.md`. Most load-bearing: `0008` abstract
  datapoint requires universal supply; `0009` per-datapoint timestamps + Kafka log-append ingestion
  time; `0010` perimeter hardening without VNet; `0011` ULID `ene_` device id; `0012`/`0013` external
  MDM identity vs. internal ENE identity (devices/sites); `0014` CloudEvents tracing; `0016`
  ClickHouse device-id enrichment; `0018` property-store append-only history; `0019` Panasonic OAuth
  env routing; `0020` HEMS resolves MDM device id for control-api.
- `docs/conventions/` — `identifier-naming.md`, `linear-estimates.md`, `linear-board-structure.md`,
  `signoz-dashboards.md`, `agent-worktree-collisions.md`.
- `docs/architecture/` (`service-registry.md`, `architecture.drawio`), `docs/infrastructure/databases.md`
  (per-DB schema table), `docs/operations/`, `docs/runbooks/`, `docs/testing/`.

## Non-negotiable rules a plan must respect

- **Conventional Commits, always** — every commit message *and* the PR title:
  `<type>(<scope>): <subject> [(ENE-123)]`. Type ∈ `feat|fix|docs|refactor|chore|test|ci|build|perf|style|revert`;
  scope = narrowest accurate component (`supplier-proxy`, `clickhouse`, `docker`); subject lowercase
  imperative, no trailing period; Linear id in parens last. `feat: add x` and `[ENE-123] Add x` are
  both rejected.
- **`./tmp/`, never `/tmp/`** — scratch files, downloaded CI artifacts and debug output go under the
  repo-root `tmp/` (gitignored) so work stays visible in the workspace.
- **Migrations are forward-only and structure-only.** Versioned `*.up.sql` + `*.down.sql` under
  `services/<svc>/migrations/`, applied only by `golang-migrate` — a compose sidecar locally
  (`docker/compose/infra.yml`) and `.github/workflows/_migrate.yml` in cloud. Never edit an applied
  migration; add a new one. No `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` or ClickHouse `ALTER … UPDATE`
  mutations (enforced by `scripts/checks/check-migrations-no-data-mutation.sh`), no
  `DO $$ … RAISE EXCEPTION` data-precondition guards (failure marks the version dirty and wedges
  every later migration), no service calling `migrate.Up()` from its own startup path.
- **Fail loud over silent fallback.** Discovery/config/parse failure raises with a clear message; it
  does not return a hardcoded default. In data pipelines never `.or(0)`, `.or("")`,
  `.get(key, default)` or `COALESCE(col, 0)` on a required field — missing data must error, not
  silently become zero.
- **UTC everywhere, and the name says so.** Every timestamp is UTC, serialized ISO 8601 with `Z`
  (`2026-05-14T12:00:00Z`; never `+00:00`, never naive). Every timestamp column/field carries the
  `_utc` suffix — `timestamp_utc`, `ingestion_time_utc`, `occurred_at_utc`; bare `timestamp`, `ts`,
  `time`, `at` are violations. Convert at the parser, at the system boundary. Python: use `lib/utc.py`
  (`now_utc`, `ensure_utc`, `iso_z`, `assert_iso_z`) — don't roll your own.
- **Identifiers are namespaced.** `ene_device_id` (`ene_<ULID>`) / `ene_site_id` internally,
  `mdm_asset_id` (`asset_v1_<ULID>`) / `mdm_site_id` for external MDM references,
  `supplier_device_identifier` (full spelling) for vendor serials. Never a bare `id`/`device_id`.
- **ADRs under `docs/adr/` are immutable.** Never delete or rewrite an accepted ADR. To reverse a
  decision, add a new numbered ADR and set the old one's status to `Superseded by ADR-NNNN`.
- **Comments state the non-obvious reason only** — never restate the code, no ADR/ticket references
  for provenance. Question a file's cohesion around ~500 lines; split along a real seam by ~800.

## What makes a plan actionable here

1. **Real, repo-relative file paths** for every change — `services/supplier-proxy/internal/…`,
   `tests/integration/test_x.py`, `services/property-store/migrations/00NN_*.up.sql` — marked new vs.
   modified. A step without a path is not a step.
2. **Ordered steps, each with its seam** (what it touches, what it must not), and explicit dependency
   order when a migration or contract change must land before its consumer.
3. **A verification section of literally runnable commands**: `scripts/checks/check-all.sh` (the
   pre-push gate — gofumpt, `go vet`, `go mod tidy`, golangci-lint, `go test ./...`, then ruff +
   mypy), `go test ./...` in the touched module, targeted `python -m pytest tests/<path>::<test> -v`,
   `make check`. Name the expected signal, not just the command. One cherry-picked linter is not
   verification.
4. **Test coverage named per behaviour** — happy *and* sad path — with the concrete test file and
   marker each new test belongs to. The primary tiers are `unit`, `integration`, `contract`,
   `e2e` and `bdd`; `pyproject.toml` `[tool.pytest.ini_options].markers` is the full authoritative
   list (it also defines `api`, `clickhouse`, `observability`, `nightly` and more) -- read it rather
   than guessing a marker name, because an undeclared marker is an error under `--strict-markers`.
5. **Explicit risks**: what breaks in production, which env (dev/stg/prd) is hit first, the rollback
   story, and any migration or contract change that is not backwards-compatible.
6. **Out of scope**, stated — plus the Conventional Commit type+scope the change ships under.

## Grounding discipline

Cite real paths. If you cannot verify that a file, function, table or flag exists, say so plainly —
"could not confirm where X lives; assuming `services/<svc>/…`, verify before implementing" — and mark
it as an assumption. An invented-but-confident path is worse than an admitted gap: it silently
misroutes the implementer. Prefer naming the search you would run (`rg 'symbol' services/`) over
asserting a location you did not check.
