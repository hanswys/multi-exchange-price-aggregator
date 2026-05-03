# Roadmap

15-PR implementation sequence for v1 + Phase 2. The design doc at
`~/.gstack/projects/multi-exchange-price-aggregator/hans-main-design-20260425-233519.md`
is the spec; this file is the order-of-operations.

**Critical path to MVP:** PRs #1 → #11 (eleven PRs to a complete portfolio v1).
**Optional:** PRs #12-15 (CI, Phase 2 anomaly, ETH pair, cloud deploy).

PR #3 is the project's thesis. If a reviewer reads only one diff, it's #3.

---

## Phase 1: Foundation (PRs 1–3)

### PR #1: Project skeleton

**Title:** `chore: rails new + docker-compose + /healthz`

- `rails new . --database=postgresql --css=tailwind --javascript=esbuild --skip-test` (full Rails, NOT `--api`)
- Gemfile additions: `sidekiq`, `redis`, `faraday`, `oj`, `rspec-rails`, `webmock`, `vcr`, `mock_redis`, `cuprite`, `rubocop-rails`, `brakeman`, `turbo-rails`, `stimulus-rails`, `cssbundling-rails` (Tailwind). `faraday-retry` was originally listed but dropped in Phase 2 (PR #8) — see `docs/adr/0001-source-adapter-fetch-contract.md` for why we hand-roll the retry loop instead.
- `docker-compose.yml` services:
  - `web` (Rails + Puma)
  - `worker` (Sidekiq)
  - `db` (`timescale/timescaledb-ha:pg16`)
  - `redis` (`redis:7-alpine`)
- `bin/setup` and `bin/dev` extended for Sidekiq + Redis
- `GET /healthz` returning `{status: "ok", db: "ok", redis: "ok", sources_healthy: 0}` (sources_healthy = 0 since no adapters yet — populated in PR #5)
- README placeholder: project goal one-liner
- Configure RSpec, set `Rails.application.config.active_job.queue_adapter = :sidekiq`

**Reviewable as:** "the skeleton is alive — `docker compose up && curl localhost:3000/healthz` returns 200."

---

### PR #2: Data shape — ticks hypertable + Tick model + PORO + converter

**Title:** `feat(schema): ticks hypertable with PORO/AR boundary`

- Migration:
  - `execute "CREATE EXTENSION IF NOT EXISTS timescaledb"`
  - `create_table :ticks` with columns:
    - `exchange:string, null: false`
    - `pair:string, null: false`
    - `price:decimal, precision: 20, scale: 8, null: false`
    - `quote_volume_24h:decimal, precision: 28, scale: 8, null: false`
    - `source_ts:datetime, null: false`
    - `ingested_ts:datetime, null: false`
  - `execute "SELECT create_hypertable('ticks', 'ingested_ts', if_not_exists => TRUE)"`
  - `add_index :ticks, [:exchange, :pair, :ingested_ts], order: { ingested_ts: :desc }, name: 'idx_ticks_lookup'`
- `app/models/tick.rb` (ActiveRecord):
  - `validates :exchange, :pair, :price, :quote_volume_24h, :source_ts, presence: true`
  - `to_value` returns `Aggregator::Tick.new(...)`
  - `Tick.recent_values(window: Aggregator::Constants::AGGREGATION_WINDOW)` class method (returns array of POROs)
- `app/aggregator/tick.rb` (PORO): value object with `ActiveModel::Validations`, attributes match `to_value` output
- Specs for both, including the round-trip via converter

**Reviewable as:** "the data shape is decided. NUMERIC prices, Timescale hypertable, explicit boundary between persistence and pure-Ruby kernel."

---

### PR #3: Correctness kernel + replay spec (the thesis statement)

**Title:** `feat(aggregator): correctness kernel with replay spec + 5 silent-failure specs`

- `app/aggregator/constants.rb` — single source of truth:
  ```ruby
  module Aggregator::Constants
    POLLING_INTERVAL    = 2.0           # seconds
    AGGREGATION_WINDOW  = 10.seconds
    STALENESS_SLO       = 10.seconds
    MAD_K               = 5.0
    MIN_SOURCES         = 2
    RETRY_BACKOFF_MS    = [250, 1_000, 4_000].freeze
    UNHEALTHY_TTL       = 30.seconds
  end
  ```
- `app/aggregator/aggregate.rb` — value object: `vwap`, `confidence`, `sources_used`, `sources_rejected`, `as_of`, `window_seconds`, `pair`
- `app/aggregator/core.rb` — the kernel with the inline ASCII diagram comment from the design doc:
  - `Core.compute(ticks:)` →
    - `filter_stale(ticks)` (drop ticks older than `STALENESS_SLO` vs `Time.now.utc`)
    - `filter_outliers(ticks)` (MAD-based, k=5.0, handle MAD=0 gracefully)
    - `weight_and_sum(ticks)` (24h `quote_volume` weighted, drop sources with 0 volume)
    - returns `Aggregator::Aggregate` or raises `Aggregator::InsufficientSources`
- **The thesis test:** `spec/aggregator/replay_spec.rb` with three captured fixtures under `spec/fixtures/exchanges/`:
  - `clean.json` — three sources, all healthy
  - `stale.json` — one source 12s old
  - `outlier.json` — one source at $0.01
  - Asserts the kernel rejects the bad two and returns consensus from the third with `confidence: "degraded_outlier"` and a structured rejection list
- **5 critical edge-case specs (silent-failure prevention):**
  - `core_mad_zero_spec.rb` — all 3 sources identical price, no division by zero
  - `core_zero_volume_spec.rb` — one source with `quote_volume_24h = 0` is dropped
  - `core_staleness_boundary_spec.rb` — tick at exactly 10.000s old IS rejected (off-by-one defended)
  - `core_insufficient_sources_spec.rb` — fewer than 2 raises `InsufficientSources`
  - `aggregate_serialization_spec.rb` — asserts decimal-as-string contract at the value-object level (controller arrives in PR #8 and will reuse `Aggregate#to_h.to_json`; the same shape is locked here)
- **2 supplementary specs covering design-documented Core paths:**
  - `core_dedup_spec.rb` — "MAD baseline = latest one tick per source" rule: duplicate ticks from the same exchange dedupe to the freshest
  - `core_even_median_spec.rb` — median with 4 sources averages the two middle prices

**Reviewable as:** "the project's thesis is testable. No HTTP, no DB, no Rails — just the math, with all 5 silent-failure modes covered. This is the README's 'Things That Will Lie To You' in code."

---

## Phase 2: First adapter end-to-end (PRs 4–5)

### PR #4: Faraday base + Binance adapter

**Title:** `feat(sources): Binance adapter with VCR contract spec`

**Status:** SHIPPED (PR #8). Notes below describe the as-shipped surface.

- `app/aggregator/sources/base.rb` — Faraday wiring + hand-rolled retry loop reading `Aggregator::Constants::RETRY_BACKOFF_MS` directly (no `faraday-retry` middleware — see `docs/adr/0001-source-adapter-fetch-contract.md`). Honors `Retry-After` on 429, capped at `Constants::RETRY_AFTER_MAX_S` (30s) so a hostile server can't pin a Sidekiq worker. Redis-backed circuit breaker fails OPEN if Redis is unreachable. After 3 retry attempts (4 total attempts) fail, marks the Source unhealthy for `UNHEALTHY_TTL` (30s) and raises `Aggregator::Sources::Unreachable`.
- `app/aggregator/sources/binance.rb` — `#fetch(pair) → Aggregator::Tick`:
  - GET `/api/v3/ticker/24hr?symbol=BTCUSDT` (weight 2 → 5% of the 1200/min IP budget at 2s polling)
  - Normalizes `BTCUSDT` → `BTC-USD` canonical via `SYMBOL_MAP`
  - Millisecond-precision `source_ts` from Binance's `closeTime`
  - Returns `Aggregator::Tick.new(exchange: "binance", pair: "BTC-USD", ...)` or raises `Sources::Unhealthy` / `Sources::Unreachable` / `Sources::MalformedResponse`
- Exception family: `Aggregator::Sources::Error` ← `Unhealthy`, `Unreachable`, `MalformedResponse`. `RateLimited` is internal-only — collapsed into `Unreachable` after retries exhaust.
- `Aggregator::REDIS_POOL` — app-owned `ConnectionPool` (size 5) decoupled from Sidekiq, defined in `config/initializers/aggregator_redis.rb`.
- VCR-recorded contract spec: happy path with query-param assertion.
- `binance_rate_limit_spec.rb`: 5 specs covering 429 + Retry-After honored, no-Retry-After fallback, HTTP-date fallback, oversized Retry-After capped, 4× 429 → Unreachable + circuit opens.
- `binance_unreachable_spec.rb`: 5xx ×4, Faraday::ConnectionFailed ×4, Faraday::TimeoutError ×4 each → Unreachable + Unhealthy. Plus transient-5xx → 200 recovery.
- `binance_unhealthy_spec.rb`: open-circuit short-circuit (no HTTP), expired-TTL allows fetch.
- `binance_parse_spec.rb`: missing field → MalformedResponse, non-object body → MalformedResponse, non-numeric `lastPrice` → MalformedResponse, non-integer `closeTime` → MalformedResponse, unknown pair → ArgumentError (no HTTP).
- `lib/tasks/aggregator.rake` → `rake aggregator:fetch[binance,BTC-USD]` prints a 6-line normalized Tick block (manual smoke test).

**Reviewable as:** "we can pull live data from Binance and normalize it into the kernel's value object. First 'oh, it works' moment." Smoke-tested live against Binance during /ship.

---

### PR #5: Self-rescheduling polling for Binance + supervisor

**Title:** `feat(polling): self-rescheduling Sidekiq pipeline + supervisor`

**Status:** SHIPPED (PR #9). Several design decisions changed during implementation
and are captured in `docs/adr/0002-polling-chain-lifecycle.md`. As-shipped:

- `app/sidekiq/exchange_poll_job.rb` — `perform(name)` resolves the adapter via
  `Aggregator::Sources.adapter_for(name)`, fetches one Tick, persists it, and
  self-reschedules `POLLING_INTERVAL` (2.0s) later. Per-exception verdicts:
  `Unreachable` and `Unhealthy` kill the chain (supervisor revives in ≤60s);
  `MalformedResponse` continues; unrescued `StandardError` propagates to the
  Sidekiq dead set as the audit trail. `retry: 0` ensures the supervisor is the
  sole recovery mechanism.
- `app/sidekiq/poller_supervisor_job.rb` — self-rescheduling at start of perform,
  no `sidekiq-cron`. Iterates `Aggregator::Sources::REGISTRY`; revives a chain
  when latest Tick is older than `AGGREGATION_WINDOW` (10s, not 30s) **and** the
  Source is not currently `Unhealthy`.
- `app/aggregator/sources.rb` — frozen `REGISTRY = %w[binance].freeze` plus
  `Sources.adapter_for(name)` allowlist + `const_get` resolution. Coinbase and
  Kraken append in PR #6 and #7.
- `app/aggregator/sources/base.rb` — `unhealthy?` lifted to a class method so
  the supervisor checks circuit state without instantiating an adapter.
- `config/initializers/poller.rb` — `Aggregator::Poller.kick!` runs in
  `after_initialize` (autoload-safe), gated on `Sidekiq.server?`. Kicks the
  supervisor instead of enqueuing chains directly — single liveness predicate.
- `config/sidekiq.yml` — concurrency 8, dedicated `polling` queue.
- `config/initializers/sidekiq.rb` — `:average_scheduled_poll_interval = 1` so
  `perform_in(2.0)` actually fires near 2s (default ~5–7s would silently break
  the rate-limit math).
- `/healthz` — `sources_healthy` is the count of distinct Sources with a Tick in
  the last `AGGREGATION_WINDOW`. Status stays 200 regardless; `/price/:pair`
  carries output-readiness in PR #8.
- Specs: 16 new examples across 6 files (job lifecycle × 5, supervisor × 5,
  initializer × 2, registry × 4, base class methods × 3, healthz × 2). Total
  suite: 76 → 92 examples.
- Smoke tested live against Binance (48 Ticks ingested over 2 minutes; manual
  Unhealthy gate exercise verified the supervisor refuses revival and resumes
  on circuit clear).

**Reviewable as:** "data flows into Postgres autonomously every 2 seconds. One recovery path — the supervisor — by design (ADR 0002)."

---

## Phase 3: Two more exchanges (PRs 6–7)

### PR #6: Coinbase adapter

**Title:** `feat(sources): Coinbase adapter`

- `app/aggregator/sources/coinbase.rb` — uses Coinbase Advanced Trade API (`/api/v3/brokerage/products/BTC-USD/ticker`)
- VCR contract spec
- Initializer wires Coinbase poller alongside Binance
- README's symbol mapping table updated

**Reviewable as:** "second source online. Two of three."

---

### PR #7: Kraken adapter (the quirky one)

**Title:** `feat(sources/kraken): adapter + VCR contract + ADR 0004`

**Status:** SHIPPED (PR #11). Four coupled per-adapter decisions are
recorded in ADR 0004. As-shipped:

- `app/aggregator/sources/kraken.rb` — `#fetch(pair) → Aggregator::Tick`:
  - GET `/0/public/Ticker?pair=XXBTZUSD` (no auth; ~0.5 req/s — half of
    Kraken's ~1 req/s soft cap)
  - `SYMBOL_MAP {"BTC-USD" => "XXBTZUSD"}` — the X/Z asset-prefix is the
    request param AND the response `result` hash key, so `result.fetch(native)`
    is an explicit assertion (an altname rewrite to e.g. `XBTUSD` raises
    MalformedResponse, not silent parse-of-first-value)
  - 200-with-non-empty-`error`-array envelope → `MalformedResponse`
    (Kraken signals app-level errors as 200, never 4xx)
  - `source_ts` from HTTP `Date` response header (no body-level
    timestamp, same as Coinbase per ADR 0003)
  - `quote_volume_24h = v[1] × p[1]` — uses Kraken's true 24h VWAP, the
    most authoritative figure it exposes (Binance: native `quoteVolume`;
    Coinbase: `volume × price` because no VWAP)
  - Hardening folded in from /ship adversarial review: 256-char
    truncation on upstream-controlled exception strings; reject
    `BigDecimal("NaN"/"Infinity")` and zero-or-negative price
- REGISTRY append wires Kraken into the supervisor's iteration order
  (per ADR 0002 the supervisor is the single source of truth — no
  initializer change)
- VCR contract spec asserts the X/Z-prefix native symbol round-trip on
  the wire
- 25 parse/edge-case specs covering error envelope (5), result-key
  lookup (4), Date header (3), malformed payload (5), non-finite
  numeric guards (4), tolerant error-envelope shapes (4)
- Pre-existing `poller_supervisor_job_spec.rb` regression fixed
  (REGISTRY-aware via `tick_for(name, age:)` helper — would have
  silently broken once Coinbase shipped, only surfaced now because
  Kraken made the test count off-by-2 instead of off-by-1)
- README's symbol mapping table extended; "no shared `SymbolMapper`"
  bullet leads with the *coupling* argument (mapping is paired with
  response-shape decisions a central table can't carry)
- TODOS.md: P2 follow-up for response-body size cap (cross-adapter
  Faraday middleware in `Sources::Base`); P3 follow-up to apply
  Kraken's finite/truncation hardening to Binance + Coinbase
- Live smoke tested: `rake aggregator:fetch[kraken,BTC-USD]` returned
  a valid Tick with second-precision `source_ts`; `/healthz` reports
  3 sources_healthy with all chains polling

**Reviewable as:** "three sources online. Integration-class spectrum
covered: clean (Coinbase), heavy weight budget (Binance), quirky
symbols (Kraken)." Smoke-tested live during /ship.

---

## Phase 4: API + dashboard (PRs 8–10)

### PR #8: JSON API

**Title:** `feat(api): GET /price/:pair with structured response + 503 path`

- `app/controllers/api/v1/base_controller.rb`:
  - `protect_from_forgery with: :null_session`
  - `rack-cors` configured: `allow { origins '*'; resource '/price/*', headers: :any, methods: [:get] }`
- `app/controllers/api/v1/prices_controller.rb#show`:
  - Calls `Aggregator::Core.compute(ticks: Tick.recent_values)`
  - Renders the response schema from the design doc
  - Rescues `Aggregator::InsufficientSources` → 503 with `insufficient_sources` envelope
- Routes: `get '/price/:pair', to: 'api/v1/prices#show'` (constraint to canonical pair list)
- Invalid pair returns 404 with clear envelope
- Request specs:
  - 200 with all 3 sources healthy
  - 200 with `confidence: "degraded_outlier"`
  - 200 with `confidence: "degraded_unreachable"`
  - 503 with `insufficient_sources` envelope
  - **decimal-as-string serialization** (1st critical edge-case spec — `parsed["vwap"].is_a?(String)`)

**Reviewable as:** "the product is real. `curl localhost:3000/price/BTC-USD` returns the structured consensus. Hiring manager can hit it without opening the dashboard."

---

### PR #9: Hotwire dashboard (static, no live updates yet)

**Title:** `feat(dashboard): instrument-panel layout with all 5 interaction states`

- `app/controllers/dashboard_controller.rb#show`
- `app/views/dashboard/show.html.erb` — full instrument-panel layout from variant B mockup
  - Reference: `~/.gstack/projects/multi-exchange-price-aggregator/designs/dashboard-20260426/variant-B-instrument-panel.html`
- `app/assets/stylesheets/application.css` — design tokens locked from the design doc:
  - 9 CSS variables (surface/ink/semantic colors)
  - Typography scale (7 sizes, 132px hero down to 10px label)
  - Numeric formatting helpers
- All 5 interaction states render correctly when data backs them:
  - Loading skeleton (DOM rendered, Action Cable not yet subscribed)
  - Empty state ("Waiting for first tick from each source. This usually takes one polling cycle (~2s).")
  - Partial (degraded_outlier and degraded_unreachable)
  - Error/503 (last-good-price fallback within 60s window)
  - Disconnect (chrome bar dot turns amber, "RECONNECTING…")
- Stimulus controllers: `dashboard-pause` toggle, `expand-rejection-detail`
- ARIA landmarks: `<header role="banner">`, `<main>`, `<section aria-labelledby>` per pane, `aria-live="polite"` on consensus
- `prefers-reduced-motion` media query removes the 200ms ease (color still changes)
- Capybara + Cuprite system spec for happy-path render

**Reviewable as:** "the dashboard renders. It's static — refresh to see new data — but every interaction state is reachable. Color contrast verified against WCAG AA."

---

### PR #10: Live updates via decoupled `BroadcastTickJob`

**Title:** `feat(dashboard): live updates via Action Cable + Turbo Streams`

- `app/sidekiq/broadcast_tick_job.rb`:
  - Self-rescheduling 1s cadence (decoupled from polling, eng review issue 5)
  - Reads `Tick.recent_values`, computes via `Aggregator::Core.compute`
  - Broadcasts via `Turbo::StreamsChannel.broadcast_replace_to(:price_BTC_USD, target: "consensus_price", partial: "dashboard/consensus", locals: { agg: ... })`
  - Falls back to "no broadcast" if compute raises `InsufficientSources` (the dashboard's 503-state view stays rendered)
- `config/cable.yml`:
  - production: redis adapter, sharing Sidekiq's `REDIS_URL`
- Stimulus `flash-controller`:
  - On Turbo Stream replace, compares new price to old, adds `flash-up` or `flash-down` class for 200ms
  - CSS: `transition: background-color 200ms ease-out; .flash-up { background: color-mix(in oklch, var(--ok), transparent 90%); } .flash-down { background: color-mix(in oklch, var(--bad), transparent 90%); }`
- Live page title: Stimulus controller updates `<title>` to `BTC-USD · ${price} — Aggregator` on each broadcast
- Initializer adds `BroadcastTickJob.perform_async if Sidekiq.server?`
- System spec verifies a stub broadcast updates the DOM

**Reviewable as:** "open `localhost:3000` and the consensus price updates once per second with a subtle flash. Tab title becomes a live ticker. **MVP done.**"

---

## Phase 5: Polish (PRs 11–13)

### PR #11: README v1 — the deliverable

**Title:** `docs: README v1 — the actual artifact`

Sections in order:

1. Response example (curl + JSON)
2. "Three exchanges, because the fourth one was lying on Tuesday"
3. Quickstart (`docker compose up` first; "Without Docker" second)
4. **Why Rails for an aggregator?** (defends the unconventional choice)
5. **Why Hotwire (not React)?**
6. **Why Sidekiq, not Solid Queue?** (the TODO from eng review)
7. **Things That Will Lie To You:** clock skew, stale data, outliers, weighting (each ~3 paragraphs with concrete examples)
8. **The math:** kernel constants table (verbatim from design doc), `quoteVolume`-weighted consensus formula, MAD definition, "why we don't call this true VWAP"
9. **Architecture diagram** (ASCII, reflects the decoupled poll → broadcast pipeline)
10. **What I didn't build and why:** Phase 2 (anomaly), sound, mobile, production deploy, retention policy, SymbolMapper extraction, Solid Queue evaluation
11. CI badge

Budget: **8-10 hours** of writing. The README IS the deliverable.

**Reviewable as:** "the README earns the test suite. A hiring manager who reads only this and skims `tests/` knows the project's thesis."

---

### PR #12: CI workflow

**Title:** `chore(ci): GitHub Actions for RSpec + Rubocop + Brakeman`

- `.github/workflows/ci.yml`:
  - Service container: `timescale/timescaledb-ha:pg16` (same image as docker-compose — green CI proves reviewer's experience works)
  - Service container: `redis:7-alpine`
  - Steps: `bundle install`, `bin/rails db:create db:migrate`, `bundle exec rspec`, `bundle exec rubocop`, `bundle exec brakeman --no-pager`
- README CI badge linked to workflow

**Reviewable as:** "green CI proves the reviewer's experience works. The badge is part of the artifact."

---

### PR #13: Phase 2 — anomaly module + synthetic divergence fixture

**Title:** `feat(anomaly): rolling-window divergence tracker + synthetic regression fixture`

- Migration: `add_column :ticks, :divergence_score, :decimal, precision: 10, scale: 4`
- `app/aggregator/anomaly.rb` — rolling-window divergence tracker:
  - For each new tick, compute `(price - cross_source_median) / cross_source_mad` over last 30s
  - Tag `tick.divergence_score`
  - If sustained `> 3σ for 4s+`, flag for rejection with reason `"divergence > 3σ for Xs"`
- `spec/fixtures/exchanges/synthetic-divergence.json` — hand-crafted (Binance prints -10% for 4s while Coinbase + Kraken stay flat)
- `spec/aggregator/anomaly_spec.rb` — replay against synthetic fixture, asserts Binance gets rejected with the divergence reason
- `Aggregator::Core` updated to consume `divergence_score` in addition to MAD outlier check
- Response schema gets a new rejection reason: `{exchange: "binance", reason: "divergence", detail: "divergence > 3σ for 4s"}`
- Dashboard rejection log updated to show divergence reason
- README v2 update: "When 2 of 3 agree and one doesn't, who's right?" section using the synthetic fixture as the running example

**Reviewable as:** "the anomaly story is real. Synthetic fixture proves it works; a real captured event will replace it whenever one occurs."

---

## Phase 6: Future / optional (PRs 14–15)

### PR #14: ETH-USD pair (Phase 1.5)

**Title:** `feat(pairs): ETH-USD support`

- Per-adapter ETH symbol mapping (`ETHUSDT` / `ETH-USD` / `XETHZUSD`)
- `PricesController` route accepts `ETH-USD`
- `ExchangePollJob` parameterized by `(exchange, pair)`, supervisor + initializer enqueue per (exchange, pair) combination = 6 polling chains
- Dashboard adds a tabbed pair switcher (Stimulus controller — `pair-tabs`)
- `BroadcastTickJob` parameterized, broadcasts to `:price_BTC_USD` and `:price_ETH_USD`
- README updated; symbol mapping table includes ETH row

**Reviewable as:** "the pipeline is generic. Adding pairs is config + view code. Architecture supports N pairs."

---

### PR #15: Optional Render deploy + live demo

**Title:** `chore(deploy): render.yaml blueprint + live demo URL`

- `render.yaml` blueprint:
  - Web service (Rails + Puma)
  - Worker service (Sidekiq)
  - Redis instance
  - Postgres: external — link to Timescale Cloud free tier (Render Postgres doesn't support Timescale natively)
- "Deploy to Render" button in README
- Live demo URL added once deployed
- README's "What I didn't build and why" updated: production deploy is now technically done, but it's still a stretch — local-first remains the load-bearing experience

**Reviewable as:** "anyone can click and try the live aggregator without `docker compose up`. Optional flex."

---

## Sequencing notes

- **PRs #1-3 are blocking for everything else.** No parallelism.
- **PRs #6-7** (Coinbase + Kraken adapters) can be done in parallel after #5 ships, in two worktrees.
- **PR #11** (README) can be drafted in parallel with PRs #5-10 — the design doc has most of the content already.
- **PRs #12-15 are independent of each other** once #11 ships.
- **MVP stop point: PR #10.** If you only ship 10 PRs, the project is complete (just no README polish).
- **Portfolio-ready stop point: PR #11.** README + dashboard + tests = artifact.
- **"What I'd do for production" stop point: PR #13.** Phase 2 anomaly is the third act.

## Done definition (per PR)

Every PR is "done" when:
- Tests pass locally and in CI
- Rubocop + Brakeman clean
- README updated where the PR changes user-visible behavior or design tokens
- One squashed commit, descriptive message, no "fix typo" follow-ups
- A 1-paragraph PR description explaining what changed and why a reviewer should care
