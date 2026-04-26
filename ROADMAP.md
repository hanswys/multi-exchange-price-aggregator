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
- Gemfile additions: `sidekiq`, `redis`, `faraday`, `faraday-retry`, `oj`, `rspec-rails`, `webmock`, `vcr`, `cuprite`, `rubocop-rails`, `brakeman`, `turbo-rails`, `stimulus-rails`, `cssbundling-rails` (Tailwind)
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
  - `prices_serialization_spec.rb` — placeholder spec asserting decimal-as-string contract (controller arrives in PR #8, but the assertion shape is fixed here)

**Reviewable as:** "the project's thesis is testable. No HTTP, no DB, no Rails — just the math, with all 5 silent-failure modes covered. This is the README's 'Things That Will Lie To You' in code."

---

## Phase 2: First adapter end-to-end (PRs 4–5)

### PR #4: Faraday base + Binance adapter

**Title:** `feat(sources): Binance adapter with VCR contract spec`

- `app/aggregator/sources/base.rb` — Faraday wiring:
  - JSON middleware (request + response via `oj`)
  - `faraday-retry` with `Aggregator::Constants::RETRY_BACKOFF_MS` exponential backoff
  - Custom middleware to honor `Retry-After` header on 429s (don't exponential-backoff over a server-told sleep)
  - Per-instance circuit-breaker: after 3 retries fail, mark unhealthy for `UNHEALTHY_TTL` (30s) via Redis key
- `app/aggregator/sources/binance.rb` — `#fetch(pair) → Aggregator::Tick`:
  - GET `/api/v3/ticker/24hr?symbol=BTCUSDT` (or `/ticker/price` if rate-limit margin tighter)
  - Normalizes `BTCUSDT` → `BTC-USD` canonical
  - Returns `Aggregator::Tick.new(exchange: "binance", pair: "BTC-USD", ...)`
  - Adapter class docstring: rate-limit budget calculation
- VCR-recorded contract spec: happy path
- `binance_rate_limit_spec.rb`: WebMock 429 with `Retry-After: 5`, assert adapter sleeps 5s (5th critical edge-case spec)
- `lib/tasks/aggregator.rake` → `rake aggregator:fetch[binance,BTC-USD]` prints normalized tick (manual smoke test)

**Reviewable as:** "we can pull live data from Binance and normalize it into the kernel's value object. First 'oh, it works' moment."

---

### PR #5: Self-rescheduling polling for Binance + supervisor

**Title:** `feat(polling): self-rescheduling Sidekiq pipeline + supervisor`

- `app/sidekiq/exchange_poll_job.rb`:
  - `perform(exchange_name)` → fetcher.fetch → `Tick.create!` → `self.class.perform_in(POLLING_INTERVAL.seconds, exchange_name)` at the end
  - Failure isolation: rescue `Aggregator::Sources::Unreachable`, log, do NOT re-enqueue (supervisor handles this)
- `app/sidekiq/poller_supervisor_job.rb`:
  - Runs every minute via `sidekiq-cron` (`config/sidekiq.yml` cron entry)
  - For each known exchange: if `Tick.where(exchange:).maximum(:ingested_ts) < 30.seconds.ago` → re-enqueue `ExchangePollJob`
- `config/initializers/poller.rb`:
  - Gated on `if Sidekiq.server?` — does NOT fire from web/console/test (eng review issue 2)
  - Initial enqueue per known exchange
- Specs:
  - Job runs end-to-end against VCR fixtures
  - Supervisor re-enqueues a stale exchange
  - Initializer is no-op in `Rails.env.test?` (asserts no jobs enqueued)
- `/healthz` updated to count `sources_healthy` from recent ticks

**Reviewable as:** "data flows into Postgres autonomously every 2 seconds. Crash-resilient — Sidekiq retry + supervisor watchdog."

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

**Title:** `feat(sources): Kraken adapter with raw-symbol translation`

- `app/aggregator/sources/kraken.rb` — handles `XXBTZUSD` raw → `BTC-USD` canonical
- VCR contract spec specifically covers the raw-symbol translation
- Initializer wires Kraken
- README's "What I didn't build and why" gets a paragraph defending the no-`SymbolMapper`-extraction call:
  > "I considered extracting symbol normalization into a shared `SymbolMapper`. I didn't — Kraken's `XXBTZUSD` quirks are more readable when they live next to the rest of the Kraken adapter than buried in a generic mapping table. Three adapters is small enough that DRY would obscure intent rather than save code."

**Reviewable as:** "three sources online. Integration-class spectrum covered: clean (Coinbase), heavy weight budget (Binance), quirky symbols (Kraken)."

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
