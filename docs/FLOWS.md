# Runtime flows

Engineer-facing tour of the five flows you'll need to understand to debug,
extend, or review this codebase. Each section: the diagram, the code path
in `file:line` form, and the failure-mode branches.

If you're after *why* a flow is shaped the way it is, the ADR linked in
each section is the canonical answer. This document is the *what*.

Vocabulary (Source, Tick, Polling chain, Broadcast chain, Unhealthy,
Aggregate, Confidence, Rejection) is defined in
[`CONTEXT.md`](../CONTEXT.md). Don't re-read this doc without it open.

---

## 1. Polling chain — Source → Tick row

How prices get into Postgres. One **Polling chain** per Source; each chain
is a self-rescheduling Sidekiq job. The Supervisor is the only thing that
can resurrect a dead chain.

```
                      Sidekiq boot
                           │
                           ▼
            config/initializers/poller.rb
            (kicks PollerSupervisorJob once)
                           │
                           ▼
          ┌─── PollerSupervisorJob#perform ───┐
          │   re-enqueues itself in 60s       │
          │   for each Source in REGISTRY:    │
          │     skip if Unhealthy             │
          │     skip if latest Tick fresh     │
          │     else perform_async(name)      │
          └───────────────┬───────────────────┘
                          │
                          ▼
          ┌─── ExchangePollJob#perform ──────┐
          │   adapter = Sources.adapter_for  │
          │   tick    = adapter.fetch(...)   │  ─── raises Sources::Error
          │   Tick.create!                   │
          │   perform_in(POLLING_INTERVAL)   │      (see §4 for branches)
          └──────────────────────────────────┘
                          │
                          ▼
                Tick row in Postgres
                (ingested_ts = NOW())
```

Code:

- Boot kick — [`config/initializers/poller.rb:20`](../config/initializers/poller.rb)
- Supervisor — [`app/sidekiq/poller_supervisor_job.rb`](../app/sidekiq/poller_supervisor_job.rb)
- Poll job — [`app/sidekiq/exchange_poll_job.rb`](../app/sidekiq/exchange_poll_job.rb)
- Adapter contract — [`app/aggregator/sources/base.rb:49`](../app/aggregator/sources/base.rb) (`#fetch`)

Constants: `POLLING_INTERVAL = 2.0s`, `SUPERVISOR_INTERVAL = 60s`,
`AGGREGATION_WINDOW = 10s` — staleness threshold used by both the
Supervisor and the kernel.

Branches at `ExchangePollJob#perform`:

| Adapter raises          | Action                                | Chain |
| ----------------------- | ------------------------------------- | ----- |
| `Unreachable`           | Log, **no reschedule**                | Dead  |
| `Unhealthy`             | Log, **no reschedule**                | Dead  |
| `MalformedResponse`     | Log, **continue to reschedule**       | Live  |
| Tick returned           | Persist, reschedule                   | Live  |

A dead chain stays dead until the Supervisor's next tick (≤60s). The
Supervisor itself never dies — `retry: 0` plus an unconditional
self-reschedule at the top of `#perform` means even if the body raises
it has already enqueued the next run.

See [ADR 0002](adr/0002-polling-chain-lifecycle.md) for why kill-and-revive
beats retry-with-backoff, and [ADR 0001](adr/0001-source-adapter-fetch-contract.md)
for the adapter contract.

---

## 2. API read — `/price/BTC-USD` → JSON

Stateless read path. No request ever blocks on a network call; the
controller reads what the polling chains have already persisted.

```
GET /price/BTC-USD
        │
        ▼
Api::V1::PricesController#show
        │
        ├─ pair ∉ CANONICAL_PAIRS ──→ 404 unknown_pair
        │
        ├─ Tick.recent_values(window: 10s)
        │       (last tick per Source, by ingested_ts)
        │
        ├─ missing = REGISTRY − seen_exchanges
        │       (synthesize one `unreachable` row per missing Source)
        │
        ├─ Aggregator::Core.compute(ticks:)
        │       │
        │       ▼
        │   ticks ─ filter_stale ─ filter_zero_volume ─ filter_outliers ─ weight_and_sum
        │              │                  │                  │
        │              ▼                  ▼                  ▼
        │           {stale}          {unreachable*}      {outlier}
        │              └────────────── rejections ─────────┘
        │       │
        │       ├─ kept.size ≥ MIN_SOURCES ──→ Aggregate
        │       │
        │       └─ kept.size <  MIN_SOURCES ──→ raise InsufficientSources
        │
        ├─ 200 OK with envelope:
        │       Aggregate#to_h + sources_rejected ++ missing
        │
        └─ rescue InsufficientSources:
                503 envelope with sources_rejected ++ missing
```

Code:

- Controller — [`app/controllers/api/v1/prices_controller.rb`](../app/controllers/api/v1/prices_controller.rb)
- Kernel — [`app/aggregator/core.rb`](../app/aggregator/core.rb)
- Tick window query — [`app/models/tick.rb:18`](../app/models/tick.rb) (`Tick.recent_values`)

The five-stage filter (stale → zero-volume → outlier → weight) is
deterministic and pure: same ticks in, same Aggregate out. Reproduce a
production aggregate from a fixture by passing the ticks to
`Aggregator::Core.compute` in a console. The kernel never reads Redis,
never reads `REGISTRY`, never hits the network.

The missing-source rejection happens **outside** the kernel
([ADR 0006](adr/0006-missing-source-rejection-injection.md)): a Source
that hasn't produced a Tick in the window is invisible to `Core.compute`,
so the controller computes `REGISTRY − seen_exchanges` and appends an
`unreachable` row to `sources_rejected` on both the 200 and the 503 path.

Confidence ladder (set inside the kernel, surfaced on the 200 path only):

| kept | rejections          | confidence              |
| ---- | ------------------- | ----------------------- |
| 3    | none                | `ok`                    |
| 2    | one `outlier`       | `degraded_outlier`      |
| 2    | one `unreachable`   | `degraded_unreachable`  |
| 2    | one `stale`         | `degraded_unreachable`  |
| <2   | (any)               | raise → 503             |

---

## 3. Broadcast chain — dashboard live updates

Independent of the polling chain. One **Broadcast chain** per Sidekiq
process, runs every 1s, recomputes the Aggregate from the same
`Tick.recent_values` the API uses, pushes a Turbo Stream update.

```
                 Sidekiq boot
                      │
                      ▼
       config/initializers/broadcaster.rb
              (Broadcaster.kick!)
                      │
                      ▼
        BroadcastTickJob.kick (NX-gated)
        ─────────────────────────────────
        if Redis key "broadcaster:in_flight" exists: no-op
        else: perform_async
                      │
                      ▼
         BroadcastTickJob#perform
         ┌──────────────────────────────────────────┐
         │ Redis SET broadcaster:in_flight EX 3     │
         │                                          │
         │ agg = Core.compute(Tick.recent_values)   │
         │                                          │
         │ Turbo::StreamsChannel.broadcast_update_to│
         │   :price_BTC_USD,                        │
         │   target:  "consensus_hero",             │
         │   partial: "dashboard/consensus"         │
         │                                          │
         │ rescue InsufficientSources:              │
         │   broadcast "dashboard/state_error"      │
         │   (same target, with last_good locals)   │
         │                                          │
         │ ensure:                                  │
         │   perform_in(BROADCAST_INTERVAL = 1s)    │
         └──────────────────────────────────────────┘
                      │
                      ▼
          ActionCable (Redis adapter in dev/prod)
                      │
                      ▼
           subscribed browsers swap innerHTML
            of <div id="consensus_hero">
```

Code:

- Boot kick — [`config/initializers/broadcaster.rb`](../config/initializers/broadcaster.rb)
- Broadcast job — [`app/sidekiq/broadcast_tick_job.rb`](../app/sidekiq/broadcast_tick_job.rb)
- Single live partial — [`app/views/dashboard/_consensus.html.erb`](../app/views/dashboard/_consensus.html.erb)
- Error partial — [`app/views/dashboard/_state_error.html.erb`](../app/views/dashboard/_state_error.html.erb)

Three things that surprised somebody enough to make it into
[ADR 0007](adr/0007-broadcast-chain-design.md):

1. **Idempotency via Redis sentinel, not a supervisor.** The 3s TTL is
   wide enough to survive one missed cycle, narrow enough that a dead
   chain releases the lock before the next Sidekiq restart. Both the boot
   kick and the self-reschedule consult the same key.
2. **No supervisor.** Broadcast is a pure read; if the chain dies the
   next Sidekiq restart resurrects it. Polling needs a Supervisor because
   a dead poll chain means data loss; a dead broadcast chain just means a
   frozen dashboard, which the Stimulus disconnect handler surfaces.
3. **`InsufficientSources` broadcasts, never skips.** A dashboard that
   stops updating during an outage is indistinguishable from one that's
   showing fresh data. The correctness thesis is "Things That Will Lie To
   You" — the dashboard included. The error partial carries
   `last_good_price` + `last_good_age` so the user sees how stale the
   freeze actually is.

Exit paths from `perform`:

| Path                          | Broadcasts?       | Self-reschedules? |
| ----------------------------- | ----------------- | ----------------- |
| Success                       | consensus partial | yes               |
| `InsufficientSources` rescue  | error partial     | yes               |
| Unrescued exception           | no                | no — dead set     |

The unrescued-exception branch is recovered by the next Sidekiq restart
(which re-runs the boot kick).

---

## 4. Source health lifecycle — Unhealthy circuit

The adapter's `#fetch` is the only place where the circuit state changes.
Tracked by the existence of a Redis key per Source with a 30s TTL.

```
                  adapter.fetch("BTC-USD")
                            │
                            ▼
                ┌── unhealthy? (Redis EXISTS) ──┐
                │                                │
                ▼                                ▼
              true                             false
                │                                │
                ▼                                ▼
       raise Unhealthy            ┌───── attempt loop (≤ 4) ─────┐
                                  │   request →                  │
                                  │     200 + parseable  → Tick  │ ──→ return
                                  │     200 + malformed  ───────┼──→ raise MalformedResponse
                                  │     429 → sleep Retry-After  │
                                  │     5xx → sleep RETRY_BACKOFF│
                                  │     network err → sleep      │
                                  └──────────────┬───────────────┘
                                                 │  budget exhausted
                                                 ▼
                              Redis SET aggregator:source:<name>:unhealthy EX 30
                                                 │
                                                 ▼
                                       raise Unreachable
```

Code:

- Adapter base — [`app/aggregator/sources/base.rb`](../app/aggregator/sources/base.rb)
- Per-source overrides — [`app/aggregator/sources/{binance,coinbase,kraken}.rb`](../app/aggregator/sources/)
- Exception hierarchy — [`app/aggregator/sources/{error,unhealthy,unreachable,malformed_response}.rb`](../app/aggregator/sources/)

Three behaviors that look like bugs but aren't:

- **`unhealthy?` fails open on Redis errors.** If Redis is unreachable
  the adapter still makes the HTTP call (which has its own timeout +
  retry). Crashing here would bypass the documented `Sources::Error`
  surface and surface a `Redis::CannotConnectError` to the poll job.
- **`mark_unhealthy!` is best-effort.** A Redis blip during the
  set-key call still produces an `Unreachable` raise to the poll job —
  the circuit just doesn't latch this round. The next failed fetch
  retries the latch.
- **MalformedResponse does not open the circuit.** The Source is
  reachable; only the payload was bad. Per-attempt log, chain
  continues at the next interval. Distinct from `Unreachable`, which
  is a single failed *attempt* (vs `Unhealthy`, which is the circuit
  being open). See `CONTEXT.md` for the exact distinction.

Interaction with the Supervisor: a Source that's `Unhealthy` is
**skipped** by the Supervisor — see
[`poller_supervisor_job.rb:12`](../app/sidekiq/poller_supervisor_job.rb).
The chain stays dead for at least `UNHEALTHY_TTL` (30s). After the key
expires the Supervisor will re-enqueue an `ExchangePollJob` on its next
60s tick.

Failure ladder for the kernel:

- A Source that's `Unhealthy` at aggregation time produces no Tick →
  controller synthesizes a missing-source rejection with reason
  `unreachable`. The kernel never sees `unhealthy` as a reason — that
  state belongs to the adapter, not the consensus.

---

## 5. Dashboard initial render — state machine

Server-rendered first paint. After this, the page is driven entirely by
the Broadcast chain (§3).

```
GET /
   │
   ▼
DashboardController#show
   │
   ├─ ?state=<override> AND Rails.env.local? ──→ stub fixture, render
   │
   └─ load_live_data
        │
        ├─ ticks   = Tick.recent_values
        ├─ missing = REGISTRY − seen
        ├─ agg     = Core.compute (or nil on InsufficientSources)
        ├─ last_good_price, last_good_age = Tick.recent_values(60s).first
        │
        └─ @state = inferred_state:
              ticks empty                   → :empty
              agg.nil?                      → :error
              agg.confidence == "ok"        → :ok
              agg.confidence == "degraded*" → :partial

   │
   ▼
app/views/dashboard/show.html.erb
   branches on @state:
     :loading | :empty | :partial | :error | :disconnect | :ok
     (only :ok and :partial render the consensus partial)
```

Code:

- Controller — [`app/controllers/dashboard_controller.rb`](../app/controllers/dashboard_controller.rb)
- View root — [`app/views/dashboard/show.html.erb`](../app/views/dashboard/show.html.erb)
- State partials — [`app/views/dashboard/_state_*.html.erb`](../app/views/dashboard/)

Two non-obvious choices:

- **The same `_consensus.html.erb` is used by the initial render and by
  every broadcast.** If you change the partial, both paths shift in
  lockstep — no "ok at render-time, degraded at broadcast-time" skew.
- **`?state=` only works in `Rails.env.local?`.** Production traffic
  cannot force the dashboard into a fake state; the override is for
  manual visual QA of `_state_*` partials.

`:disconnect` is not reachable from the controller — it's set
client-side by the Stimulus consumer-connection-status controller when
the ActionCable subscription drops. Listed in `STATES` so the override
fixture path can render it.

---

## When to update this file

- A new flow gets added or removed (e.g. a webhook ingress, a backfill
  job).
- The shape of an existing flow changes — branches, exit paths,
  partials, state names.
- A constant in `Aggregator::Constants` that appears in this file
  changes value.

Drift between this file and reality is worse than no file — if you can't
keep the ASCII diagram honest, delete the section.
