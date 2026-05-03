# Multi-Exchange Price Aggregator

[![CI](https://github.com/hanswys/multi-exchange-price-aggregator/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/hanswys/multi-exchange-price-aggregator/actions/workflows/ci.yml)

A Rails service that polls Binance, Coinbase, and Kraken for `BTC-USD`,
rejects stale and outlier prints through a deterministic correctness
kernel, and exposes a single consensus price weighted by 24h quote
volume — through a JSON API and a live Hotwire dashboard.

The interesting part is not the polling. It's what the kernel rejects
and why. Three exchanges' clocks disagree, one of them is always
laggy, and somebody's order book occasionally prints a $0.01 trade.
This repo is about treating that as the normal case.

---

## Response example

```sh
curl -s localhost:3000/price/BTC-USD | jq .
```

```json
{
  "pair": "BTC-USD",
  "vwap": "67432.18",
  "confidence": "ok",
  "as_of": "2026-04-25T23:42:00.123Z",
  "window_seconds": 10,
  "sources_used": [
    {"exchange": "binance",  "price": "67430.50", "weight": "0.42", "source_ts": "2026-04-25T23:41:58.910Z"},
    {"exchange": "coinbase", "price": "67434.00", "weight": "0.31", "source_ts": "2026-04-25T23:41:59.020Z"},
    {"exchange": "kraken",   "price": "67432.05", "weight": "0.27", "source_ts": "2026-04-25T23:41:59.450Z"}
  ],
  "sources_rejected": []
}
```

The shape is the project's thesis. Five things to notice before reading
the rest of the README:

1. **`vwap`, `price`, `weight` are decimal strings.** Currency through
   IEEE-754 is a real bug; we store `NUMERIC(20,8)` in Postgres and
   serialize as strings on the way out. Tested explicitly in
   `spec/requests/api/v1/prices_spec.rb` (string-shape assertions on
   every contract test).
2. **`confidence` is enumerated, not numeric.** `ok` (all three
   contributed), `degraded_outlier` (one rejected by MAD), or
   `degraded_unreachable` (one absent or unhealthy). Below two
   contributors the response is HTTP 503, not a degraded number — see
   below.
3. **`sources_used` carries the per-source `weight`.** Each source's
   share of the consensus is visible in the response. Sums to 1.0 ±
   rounding. The reviewer can recompute the consensus by hand.
4. **`source_ts` is per-source.** That's the timestamp the exchange
   stamped on the data, not the moment we ingested it. The kernel
   rejects ticks whose `source_ts` is older than the staleness SLO
   (10s) — see "Things That Will Lie To You" below.
5. **`sources_rejected` is the failure surface.** When a source fails
   to contribute, it shows up here with a structured reason and detail
   — never silently dropped:

```json
{"exchange": "kraken",  "reason": "stale",       "detail": "source_ts age 14.2s > SLO 10s"}
{"exchange": "binance", "reason": "outlier",     "detail": "price 65120.00 vs median 67432.05, MAD 12.1, k=387.5"}
{"exchange": "coinbase","reason": "unreachable", "detail": "3 retries failed; circuit open for 22s"}
```

When fewer than two sources are healthy:

```sh
curl -s -i localhost:3000/price/BTC-USD
# HTTP/1.1 503 Service Unavailable
```

```json
{
  "pair": "BTC-USD",
  "error": "insufficient_sources",
  "sources_used": 1,
  "sources_required": 2,
  "sources_rejected": [
    {"exchange": "binance", "reason": "unreachable", "detail": "circuit open for 22s"},
    {"exchange": "kraken",  "reason": "unreachable", "detail": "no tick within 10s window"}
  ]
}
```

The dashboard at `http://localhost:3000` renders the same data live
over Action Cable, updating once per second.

---

## Three exchanges, because the fourth one was lying on Tuesday

The reason there are three sources and not five is that more sources
do not improve the answer; they dilute it. Past three, you are paying
maintenance cost — adapter quirks, rate budgets, fixture
recordings — for a vote that is statistically pinned by the first
three.

The three were chosen for *integration variety*, not for redundancy:

- **Binance** — high volume, weight-based rate budget, no native
  `BTC/USD` market (we map to `BTCUSDT` and treat USD/USDT as the
  same quote currency for v1).
- **Coinbase** — clean REST, USD-native, but no `source_ts` in the
  body — the adapter pulls it from the HTTP `Date` header (see
  `docs/adr/0003-coinbase-source-decisions.md`).
- **Kraken** — legacy X/Z asset prefixing (`XXBTZUSD`), application
  errors signaled as a non-empty `error` array on a 200 response, no
  `quote_volume_24h` field (computed from `v[1] × p[1]` — see
  `docs/adr/0004-kraken-source-decisions.md`).

Each one breaks a different assumption you would otherwise bake into a
shared adapter. That is the point. A fourth adapter that reads like
Coinbase is signal noise; a fourth that reads like Kraken in a
different way is the v2 conversation.

The "Tuesday" in the section title is the joke version of a real
observation: pick any week of live polling and at least one source
will print something ugly — a stale tick during a maintenance window,
a wide spread during a liquidity gap, an outright wrong number for
seconds at a time. Single-source price oracles trust whoever's loudest.
Two-source oracles can't break a tie. Three is the smallest set that
lets you reject a liar.

The supported pair set is `Aggregator::Sources::CANONICAL_PAIRS` (v1:
`BTC-USD`). `ETH-USD` is one line of code away once v1 ships — the
kernel is pair-generic.

| Canonical pair | Binance            | Coinbase  | Kraken     |
|----------------|--------------------|-----------|------------|
| `BTC-USD`      | `BTCUSDT` (ticker) | `BTC-USD` | `XXBTZUSD` |

---

## Quickstart

### With Docker (the supported path)

```sh
git clone git@github.com:hanswys/multi-exchange-price-aggregator.git
cd multi-exchange-price-aggregator
cp .env.example .env       # dev-only credentials for the local containers
docker compose up
```

That's it. Wait one polling cycle (~2 seconds), then:

```sh
curl localhost:3000/healthz
# {"status":"ok","db":"ok","redis":"ok","sources_healthy":3}

curl localhost:3000/price/BTC-USD
# {"pair":"BTC-USD","vwap":"67432.18","confidence":"ok",...}

open http://localhost:3000
# live dashboard, updates once per second
```

`.env` is gitignored. `docker-compose.yml` requires `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_USER`, and
`DATABASE_PASSWORD` to be set — Compose refuses to start otherwise,
which is the right failure mode for "you forgot to copy `.env.example`."

Services brought up by Compose:

- `web` — Rails + Puma on `:3000`
- `worker` — Sidekiq running the polling and broadcast chains
- `db` — `timescale/timescaledb-ha:pg16` (Postgres 16 + TimescaleDB)
- `redis` — `redis:7-alpine` for Sidekiq + Action Cable + sentinels

The first run takes ~30s of Docker pulls; subsequent `docker compose
up` is instant.

### Without Docker

If you'd rather run bare-metal:

```sh
brew install postgresql@16 redis
brew services start postgresql@16 redis

# TimescaleDB extension is required by the v1 migration
# (CREATE EXTENSION IF NOT EXISTS timescaledb in db/migrate/).
# The Docker path bundles it; bare-metal needs it installed
# separately. See timescale.com/docs/install for your platform.
brew install timescaledb   # macOS

asdf install   # picks up .tool-versions for Ruby 3.3 and Node
bin/setup
bin/dev
```

`bin/dev` is the standard Rails Foreman-driven script: web + worker +
JS bundling + CSS bundling, all in one terminal. CTRL-C stops them
together.

### Running the tests

```sh
bundle exec rspec        # offline, replay-only
bundle exec rubocop
bundle exec brakeman
```

Specs use VCR cassettes under `spec/fixtures/exchanges/`. The kernel
specs (`spec/aggregator/`) are pure Ruby — no Rails, no DB, no
network. They are the contract; everything else is glue. CI runs the
same three commands; a green badge is the same green you got locally.

---

## Why Rails for an aggregator?

The reflexive answer is "use Python, the data science people use
Python." That's a fine answer for a notebook. It is the wrong answer
for an *application* — and what we're shipping here is an
application, not a data pipeline.

Rails brings four things this project actually leans on:

1. **Sidekiq + ActiveJob.** Self-rescheduling per-source polling
   chains plus a separate broadcast chain plus a supervisor — three
   distinct cadences with different retry semantics. Implementing
   that on top of `asyncio` and a homegrown scheduler is two weekends
   of yak-shaving I'd rather spend on the kernel.
2. **Hotwire.** A live dashboard with no separate frontend build, no
   npm pipeline, no client-side state machine — just server-rendered
   ERB and Turbo Stream broadcasts. See "Why Hotwire, not React"
   below.
3. **ActiveRecord migrations + raw SQL.** The `ticks` migration
   issues `CREATE EXTENSION timescaledb` and `SELECT
   create_hypertable(...)` directly; ActiveRecord doesn't pretend to
   abstract over Timescale, and that's a feature. Vanilla Postgres
   migrations are the same shape if you don't have the extension.
4. **The PORO/AR boundary.** Rails encourages a clean split: anything
   under `app/aggregator/` is pure Ruby with no Rails dependency
   (`Aggregator::Tick`, `Aggregator::Core`, `Aggregator::Aggregate`).
   Anything under `app/models/` knows about the database. The bridge
   is one method: `Tick#to_value`. The kernel specs run against
   POROs in milliseconds; the integration specs use the AR side.

The unconventional choice is itself the signal. A reviewer who sees
"crypto price aggregator" expects Python or Go. A reviewer who reads
the README finds an explicit defense of the choice — and that is more
interesting than another Python repo.

---

## Why Hotwire, not React?

Three reasons:

1. **The data model is server-driven anyway.** The kernel computes
   the consensus on the server every second. A React frontend would
   either re-poll the JSON endpoint (in which case it's just doing
   HTTP polling badly) or open a WebSocket back to the same Rails
   process (in which case Action Cable is already there).
2. **One Rails app, one Docker service, one dev story.** A separate
   React app means a separate build, separate deploy, separate CORS
   config, separate state synchronization. For a single dashboard
   page that mostly displays text and one sparkline, that is
   ridiculous overhead.
3. **Turbo Streams over Action Cable is purpose-built for this.** A
   `BroadcastTickJob` runs once per second, computes the latest
   `Aggregate`, and calls
   `Turbo::StreamsChannel.broadcast_update_to(:price_BTC_USD, ...)`.
   The browser receives an HTML fragment; Turbo swaps it in. There is
   no client-side state. There is barely client-side JavaScript — a
   couple of Stimulus controllers for the price-flash animation and
   the document-title ticker, both under 50 lines.

The dashboard at `app/views/dashboard/show.html.erb` is one ERB file
plus four state partials (`_state_loading`, `_state_empty`,
`_state_error`, `_state_disconnect`) and one live partial
(`_consensus`) that subsumes the OK and degraded states (see
`docs/adr/0007-broadcast-chain-design.md` for why). That's the entire
frontend.

For an `aggregator`-style app, Hotwire is correct. For a CRUD app
with rich client-side editing, React is correct. The README of a
project should explain which type of app it is.

---

## Why Sidekiq, not Solid Queue?

Solid Queue is the Rails 7.1+ database-backed default. It is excellent
for typical web-app background work — emails, image processing, daily
reports. It is the wrong choice for this project, for two specific
reasons:

1. **Sub-2-second self-rescheduling.** Solid Queue's polling worker
   runs at a configurable interval, but the dispatch latency
   compounds with self-rescheduling: a job that calls
   `perform_in(2.seconds)` lands in the queue, then waits up to one
   poll interval before being claimed, then runs. Three sources doing
   that drift visibly. Sidekiq's dedicated thread pool plus
   Redis-backed scheduled set picks the job up within tens of
   milliseconds of its scheduled time — the difference between "polls
   every 2 seconds" and "polls every 2-to-3.5 seconds, drifting."
2. **One Redis, three uses.** Sidekiq, Action Cable's pubsub adapter,
   and the broadcast-chain idempotency sentinel
   (`broadcaster:in_flight`, `SET NX EX 3` — see ADR 0007) all share
   the same Redis instance. We were going to need Redis anyway for
   Action Cable. Adding Solid Queue means *also* a Postgres
   `solid_queue_*` set of tables, and the polling-vs-pubsub split
   makes the broadcast-idempotency sentinel awkward to host.

Solid Queue's cost — DB pressure on a hot polling job — is real and
the project is designed around avoiding it. If a future v3 moves to a
WebSocket ingestion model where polling cadence stops mattering, the
Solid Queue evaluation is worth revisiting. It's listed under "What I
didn't build and why" below.

---

## Things That Will Lie To You

The premise of the project. Each subsection below is a class of
failure the consensus has to survive. The kernel's job is to surface
the lie in `sources_rejected`, not to silently absorb it.

### Clock skew

Each source stamps its own ticks with its own clock. Coinbase's `Date`
header, Kraken's `result.<pair>.t`, Binance's `closeTime`. None of
them are synchronized to each other. In practice we see ~100-300ms of
inter-source drift on a quiet day, multiple seconds during incidents.

The kernel anchors to wall-clock `Time.now.utc` and trusts the host to
be NTP-synced (`systemd-timesyncd` / `chronyd` on Linux,
`timed`/`timesyncd` on macOS). The 10-second staleness SLO is
deliberately generous to absorb sub-second NTP drift on the host.

`Process::CLOCK_MONOTONIC` is used only for *intra-process* elapsed
times — retry backoffs, request latency. Wall clock for cross-process
("how old is this tick the database has?"); monotonic for in-process
("how long has this retry been backing off?"). Mixing them is a
classic bug.

If you ever measure cross-source skew greater than 1 second
sustained, the answer is to switch to per-exchange `serverTime`
normalization — at which point the design doc becomes a multi-day
project. v1 does not do this and documents the assumption.

### Stale data

A source that's still up but no longer ticking is the most common
failure mode. The exchange's connection to its own matching engine
hiccups; the exchange keeps serving the *last* price for a few
seconds with a stale `source_ts`; the public ticker endpoint never
errors.

The kernel rejects a tick whose `source_ts` is older than
`STALENESS_SLO` (10 seconds) at compute time, with reason `"stale"`
and the actual age in `detail`. The boundary is "older than" — a tick
at exactly 10.000s is dropped. Tested in
`spec/aggregator/core_staleness_boundary_spec.rb`. Off-by-one at the
SLO is the kind of bug you only catch in production, so we test it
explicitly.

### Outliers

A fat-finger trade, a momentary book imbalance, a single exchange
disagreeing with the rest of the world. We use median absolute
deviation (MAD) instead of standard deviation — MAD is robust to the
outlier we are trying to detect, where standard deviation is *defined
in terms of* the outlier and gets pulled toward it.

The kernel computes the median price across the most-recent tick from
each source, then the MAD around that median, then rejects any tick
where `|price - median| > k × MAD`. v1 sets `k = 5.0` — conservative,
because the cost of admitting an outlier is much higher than the cost
of rejecting a legitimate price spike for a few seconds.

When all three sources print the same number, MAD is zero. Naive
implementations divide by it and crash. Tested in
`spec/aggregator/core_mad_zero_spec.rb`: the kernel handles MAD = 0
gracefully (no rejections, all sources used).

### Weighting

REST polling at 2-second intervals samples the *ticker*, not the
*trade tape*. So the "V" in VWAP is not literal trade-by-trade
volume. The honest definition is below in the math section. This is
the project's most explicit tradeoff and the README should not bury
it.

We weight by each exchange's reported 24h `quote_volume`, falling
back to dropping the source if it reports zero (rare but happens
during exchange maintenance). The README's math section disambiguates
the convention: this is a *consensus mid weighted by recent activity
level*, not a trade-by-trade VWAP. Calling it `vwap` in the response
is industry convention; calling the function `consensus_price`
internally is honesty.

The zero-volume edge case is tested in
`spec/aggregator/core_zero_volume_spec.rb` — divide-by-zero would be
an obvious crash in code review and a subtle bug under load.

---

## The math

### Constants (v1)

These values appear verbatim in `app/aggregator/constants.rb` and are
the source of truth for the dashboard's chrome bar.

| Constant | Value | Why |
|---|---|---|
| `POLLING_INTERVAL` | 2.0s | Fast enough to feel real-time, slow enough to fit under all three rate budgets with margin. |
| `BROADCAST_INTERVAL` | 1.0s | Dashboard cadence, decoupled from polling. Three sources at 2s with offset would otherwise stutter; one chain at 1s gives a steady metronome. |
| `AGGREGATION_WINDOW` | 10s | The endpoint computes from ticks ingested in the last 10 seconds. Defines "current price." |
| `STALENESS_SLO` | 10s | A tick whose `source_ts` is older than this is rejected. Same value as the window — every tick *in* the window is by definition fresh enough. |
| `MAD_K` | 5.0 | Outlier threshold. Reject ticks beyond k×MAD from the median. Conservative; tunable in config. |
| `MIN_SOURCES` | 2 | Below 2, return HTTP 503 with `reason: "insufficient_sources"`. Don't lie. |
| `RETRY_BACKOFF_MS` | [250, 1000, 4000] | Three attempts, exponential backoff, then mark the source unhealthy. |
| `UNHEALTHY_TTL` | 30s | Source stays unhealthy for this long after circuit-open before being retried. |
| `HTTP_OPEN_TIMEOUT` | 2s | Faraday connect timeout. |
| `HTTP_READ_TIMEOUT` | 5s | Faraday read timeout. |
| `RETRY_AFTER_MAX_S` | 30s | Cap on honoring `Retry-After` headers; anything bigger trips the circuit immediately. |

### The consensus formula

Let `S = {s_1, ..., s_n}` be the set of sources whose most recent
tick within `AGGREGATION_WINDOW` survived staleness and outlier
filtering, and let `p_i`, `v_i` be source `i`'s price and 24h
`quote_volume_24h`. Then:

```
                Σ p_i × v_i
consensus  =   ─────────────         (i ∈ S)
                  Σ v_i
```

The per-source `weight` returned in `sources_used` is just
`v_i / Σ v_j`, rounded to 2 decimal places for display.

### Median absolute deviation (MAD)

For the same set of fresh ticks, with prices `p_1, ..., p_n`:

```
median  =  median(p_1, ..., p_n)
MAD     =  median(|p_i - median|)
```

A tick is an outlier and rejected if:

```
|p_i - median|  >  k × MAD,    k = 5.0
```

Two edge cases worth calling out:

- **MAD = 0** (all sources agree to the cent): the kernel skips outlier
  rejection. No source is "more than k×0 away" from the median, so the
  formula degenerates harmlessly.
- **n = 2 surviving sources**: median and MAD are well-defined but
  weak (MAD is half the spread). We accept this; below
  `MIN_SOURCES = 2` we 503 anyway.

### Why this is not "true" VWAP

Real VWAP weights by *trade-by-trade* volume — every print, with its
quantity, contributes to the rolling average. We don't see trades; we
see the public ticker endpoint, which gives us the latest mid price
plus a rolling 24h cumulative volume.

So our "V" is "this exchange's recent activity level" rather than
"the volume that traded at this specific price during the
aggregation window." A high-volume exchange's price gets more weight,
which is the right behavior for a consensus oracle but is not the
same calculation as VWAP-as-defined.

The function is named `consensus_price` internally. The response
field is named `vwap` because that's what reviewers will search for
and the response shape is a contract. The README is the place to
disambiguate.

True trade-by-trade VWAP requires WebSocket trade streams from each
exchange (different endpoints, different rate semantics, very
different code path). It is the v3 conversation.

---

## Architecture

The pipeline is intentionally split into two independent cadences:
polling chains write ticks to the database, a separate broadcast chain
reads from the database and updates the dashboard.

```
PIPELINE (decoupled write/broadcast)
─────────────────────────────────────────────────────────────────────

   ┌─ ExchangePollJob[binance] ─ every 2s ─┐
   │                                       │
   │─ ExchangePollJob[coinbase] ─ every 2s ─┼──→  INSERT INTO ticks
   │                                       │     (NUMERIC prices,
   └─ ExchangePollJob[kraken]  ─ every 2s ─┘      Timescale hypertable)
              │                                          │
              │ self-reschedules; killed                 │
              │ on Unhealthy/Unreachable                 │
              ▼                                          │
   ┌─ PollerSupervisorJob ─ every 60s ─────┐             │
   │   re-enqueues any dead chain          │             │
   │   (latest tick > 30s old, source not  │             │
   │   currently Unhealthy)                │             │
   └───────────────────────────────────────┘             │
                                                         │
                                                         ▼
   ┌─ BroadcastTickJob ─ every 1s ─────────────────────────────────┐
   │   1. Tick.recent_values(window: 10s)  ──→ array of POROs      │
   │   2. Aggregator::Core.compute(ticks:) ──→ Aggregate           │
   │   3. Turbo::StreamsChannel.broadcast_update_to(               │
   │        :price_BTC_USD, target: "consensus_hero", ...)         │
   │   ─ self-reschedules; idempotency via Redis sentinel          │
   │     (broadcaster:in_flight, SET NX EX 3)                      │
   │   ─ on InsufficientSources, broadcasts _state_error           │
   │     instead of skipping (truth-telling rule, ADR 0007)        │
   └───────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
                       ┌──────────────────────┐
                       │   Hotwire dashboard  │  every connected
                       │   (one Turbo Stream  │  browser updates
                       │   subscription per   │  once per second
                       │   tab)               │
                       └──────────────────────┘

   Also serving:
   ┌─ GET /price/BTC-USD  ──→ Tick.recent_values + Core.compute
   │                          ──→ JSON envelope (200/404/503)
   └─ GET /healthz        ──→ {db, redis, sources_healthy}/{status}

   Storage: ticks hypertable on TimescaleDB (Postgres 16 + extension)
   Coordination: Redis (Sidekiq queues + Action Cable pubsub +
                        broadcast sentinel)
```

Why decoupled? Three pollers writing on their own schedules and one
broadcaster reading on its own schedule eliminates the race where a
slow Binance fetch arrives after a fresh Coinbase fetch and overwrites
the dashboard with the older snapshot. The two chains never race
because the broadcaster reads from the database, not from polling
output.

The kernel itself is a single file — see `app/aggregator/core.rb`.
Its inline ASCII diagram is the contract; the rest of the
architecture exists to call `Core.compute` correctly and present its
output truthfully.

---

## What I didn't build and why

A v1 portfolio repo earns its credibility partly by what it leaves
out. Listed roughly in order of "how often this comes up in review."

### Anomaly layer (Phase 2)

A `divergence_score` column on `ticks` plus a rolling-window tracker
(`app/aggregator/anomaly.rb`) that tags each tick with how far it
diverges from the cross-exchange consensus over the last N seconds.
Surfaces in the rejection list with reasons like `"divergence > 3σ
for 8s"`.

Held for v2 because the v1 kernel already rejects the bad ticks the
anomaly layer would tag — anomaly is for *narrative*, not for
correctness. The README's "When 2 of 3 agree and one doesn't, who's
right?" section is the v2 deliverable, paired with a real captured
flash-crash fixture (one week of running v1 will produce one).

### Audio / sound

The dashboard has no sound. A reviewer in a meeting opens the page
and is not immediately the worst person in the meeting. Adding "ping
on outlier rejection" or "tick on each broadcast" was discussed and
rejected for v1 — it's a UX that has to be earned with real
information density, and we don't have enough yet.

### Mobile / phone layout

The dashboard prioritizes desktop (≥1280px). Below 1024px the layout
collapses to a single column; below 640px it is explicitly not a
target. Phone reviewers are not the audience for a "watch the price"
HUD, and supporting a third breakpoint trades layout simplicity for
universal access. Documented in the design doc; unchanged in v1.

### Production deployment (`render.yaml` / Fly / etc.)

This is a local-first repo. `docker compose up` on a fresh laptop is
the supported reviewer experience. A live demo URL is *cooler* than a
local-only repo, but it is also a 1-2 day rabbit hole of provisioning
managed Postgres-with-Timescale (most managed Postgres providers
don't ship the extension), wiring secrets, and writing a deploy doc.
The repo is complete and reviewable without it. A `render.yaml`
blueprint may land post-v2 as a stretch.

### TimescaleDB retention policy

Once the `ticks` table has >100k rows, you'd want
`add_retention_policy('ticks', INTERVAL '30 days')` plus chunk
compression. v1 ships without it because v1 doesn't have enough data
to need it — adding it now is a config you'd never test under load.
Acknowledged here; lives in `TODOS.md`.

### `SymbolMapper` extraction

Every adapter has its own native-symbol translation: Binance's
`BTCUSDT`, Coinbase's identity `BTC-USD`, Kraken's `XXBTZUSD`. A
shared `Aggregator::SymbolMapper` would centralize the canonical →
native translation, but each adapter's translation is *paired with
response-shape decisions a central table can't carry* (Kraken keys
its `result` hash by the native symbol; Coinbase interpolates it into
a URL path; Binance sends it as a query parameter). Splitting the
two halves into different files is the wrong abstraction at three
sources. Revisit when a fourth lookalike source lands.

### Solid Queue evaluation

Discussed above — Sidekiq won on dispatch latency for sub-2-second
polling and on Redis reuse with Action Cable. That decision is worth
revisiting *only* if the polling model changes (WebSocket ingestion
in v3 would make queue dispatch latency irrelevant, at which point
Solid Queue's "no Redis required" argument starts to matter).

### Prometheus / Grafana exposition

`/metrics` lands in Phase 2 alongside the anomaly metrics, where
there's something useful to expose. v1 has nothing custom worth
graphing — adding `yabeda` plus a `prometheus` service in
`docker-compose.yml` for the sake of having metrics is the kind of
infrastructure-cosplay this README is trying to avoid. Grafana is
never shipped from this repo; that's a deployment concern, not a
project concern.

---

## Project layout

```
app/
  aggregator/             # pure Ruby — no Rails dependency
    constants.rb          # source of truth for kernel constants
    core.rb               # Core.compute(ticks:) — the kernel
    tick.rb               # Aggregator::Tick (PORO value object)
    aggregate.rb          # Aggregator::Aggregate (response shape)
    insufficient_sources.rb
    sources.rb            # REGISTRY = %w[binance coinbase kraken]
    sources/
      base.rb
      binance.rb          # BTCUSDT
      coinbase.rb         # BTC-USD (identity)
      kraken.rb           # XXBTZUSD
      error.rb
      malformed_response.rb
      unhealthy.rb        # circuit-open marker
      unreachable.rb      # single-fetch failure event
  models/
    tick.rb               # ActiveRecord — Tick#to_value bridges to PORO
  controllers/
    api/v1/prices_controller.rb   # ActionController::API
    dashboard_controller.rb       # ApplicationController (full Rails)
    health_controller.rb
  sidekiq/
    exchange_poll_job.rb          # one chain per source
    broadcast_tick_job.rb         # one chain total
    poller_supervisor_job.rb      # 60s wakeup
  views/dashboard/
    show.html.erb
    _consensus.html.erb           # subsumes ok + degraded states
    _state_loading.html.erb
    _state_empty.html.erb
    _state_error.html.erb
    _state_disconnect.html.erb
    _sources.html.erb
    _rejections.html.erb
spec/
  aggregator/             # pure Ruby specs — no Rails, no DB
    replay_spec.rb        # the thesis statement
    core_*_spec.rb        # silent-failure specs (MAD = 0, zero volume,
                          # staleness boundary, dedup, even median,
                          # insufficient sources)
  fixtures/exchanges/     # captured JSON for replay
  requests/api/v1/        # JSON contract tests
  ...
docs/
  adr/                    # architecture decisions
    0001-source-adapter-fetch-contract.md
    0002-polling-chain-lifecycle.md
    0003-coinbase-source-decisions.md
    0004-kraken-source-decisions.md
    0005-controller-layer-split.md
    0006-missing-source-rejection-injection.md
    0007-broadcast-chain-design.md
CONTEXT.md                # domain language reference
ROADMAP.md                # 15-PR implementation sequence
TODOS.md                  # deferred work
docker-compose.yml
```

`CONTEXT.md` is the domain glossary — read it if a term in this
README felt overloaded. The ADRs under `docs/adr/` carry the
*why* for individual decisions; the README carries the *why* for the
project shape.

---

## License

MIT-licensed (a `LICENSE` file lands before the `v1.0.0` tag). The
dependencies — Rails, Sidekiq, Faraday, Hotwire, RSpec — keep their
own licenses.
