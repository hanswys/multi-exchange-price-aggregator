# TODOS

Captured by /plan-eng-review on 2026-04-26.

---

## README: defend the Sidekiq choice against Solid Queue

**What:** Add a paragraph to the README's "What I didn't build and why"
section explaining why this project uses Sidekiq when Rails 7.1+ ships Solid
Queue as the default background runner.

**Why:** A 2026 reviewer reading this repo will ask "why not the new default?"
within 10 seconds of seeing `gem "sidekiq"` in the Gemfile. Pre-empting that
question in the README converts the obvious-friction-point into a
judgment-signal.

**Pros:**
- Turns a "why didn't you" gotcha into a "good, they thought about it"
- Demonstrates awareness of current Rails ecosystem
- Free signal — pure documentation, no code change

**Cons:**
- ~15 min of README writing once the project ships
- The defense has to be honest (not "I just know Sidekiq better")

**Suggested defense angle:**
- Sub-2s self-rescheduling jobs are well-trodden with Sidekiq's
  `perform_in`. Solid Queue's recurring-task primitives are coarser-grained.
- Real production experience operating Sidekiq at PostCo. The README leans
  into "this is the stack I'm senior in" framing already.
- Honest acknowledgment that for a fresh greenfield app with no prior
  ecosystem ties, Solid Queue would be the right default.

**Context:** Pure documentation, no code change. Lands in README v1
or as a v1.1 docs commit.

**Depends on:** v1 shipped first.

---

## Sources::Base — aggregate cap on time-in-loop for repeated 429s
**Priority:** P2
**Captured:** /ship adversarial review on PR #8

A worker can spend up to `RETRY_BACKOFF_MS.size * RETRY_AFTER_MAX_S` =
3 × 30 = 90 seconds inside `#fetch` if every attempt is a 429 with the
maximum honored Retry-After. Add an aggregate budget — once cumulative
sleep time crosses N seconds, open the circuit immediately rather than
honoring further Retry-After values. Or: treat any 429 with
`Retry-After >= UNHEALTHY_TTL` as "open the circuit, the IP may be banned".

---

## Sources::Base — TOCTOU + thundering herd at TTL expiry
**Priority:** P2
**Captured:** /ship adversarial review on PR #8

Current circuit-breaker is a non-atomic check-then-fetch-then-set. With
multiple concurrent workers (Phase 3 polling will have N), all workers
simultaneously bypass an open circuit between TTL expiry and the next
`mark_unhealthy!`. Mitigations: Lua atomic check-and-incr-failures, or a
half-open state where exactly one worker probes and the rest wait. Not a
v1 concern (one worker per Source at 0.5 Hz), but lands when the
supervisor/poller pipeline ships.

---

## Sources::Base — rake task can trip the production circuit
**Priority:** P3
**Captured:** /ship adversarial review on PR #8

`rake aggregator:fetch[binance,BTC-USD]` shares `Aggregator::REDIS_POOL`
with the polling pipeline. If an operator runs the task on a flaky network
and hits Unreachable, the production source is marked unhealthy for 30s
for everyone. Fix: either inject a separate "diagnostic" Redis pool from
the rake task, accept a `--dry-run` flag, or skip `mark_unhealthy!` when
invoked from the rake context.

---

## Sources adapter test harness — REDIS_POOL const-swap fragility
**Priority:** P3
**Captured:** /ship pre-landing review (Maintainability + Testing specialists)

`spec/support/aggregator_redis.rb` swaps `Aggregator::REDIS_POOL` at
load time. Any code that captures the constant earlier (memoized class
ivar, autoloaded module) keeps the production pool. Fix: either inject
the pool through `Base#initialize(redis_pool:)` per-test (already
supported), or convert REDIS_POOL into a method that lazily reads a
configurable target.

---

## Sources::Binance — connection reuse across fetches
**Priority:** P2
**Captured:** /ship adversarial review on PR #8

Default Faraday adapter (Net::HTTP) does not pool sockets across Faraday
instances. Phase 3's polling job will create one adapter per call by
default — every fetch does a fresh TCP+TLS handshake (~100-300ms). Fix:
either memoize one adapter instance per Source for the worker process
lifetime (cleanest), or switch to `net-http-persistent`. Document the
expectation in the PR that introduces the poll job.

---

## PollerSupervisorJob — heartbeat-based liveness, not just Tick recency
**Priority:** P2
**Captured:** /ship adversarial review on PR #9

Current revival predicate uses `latest Tick > AGGREGATION_WINDOW`. A
chain that's alive but slow (network stall + retry backoffs of 5–9s)
looks dead to the supervisor → duplicate chain enqueued. ADR 0002
acknowledges this for the multi-process case but the same race exists
single-process when a poll legitimately takes >10s. Fix: chain refreshes
a Redis heartbeat key with TTL `2 * POLLING_INTERVAL` on every loop;
supervisor revives only when the heartbeat is missing. Lands when the
multi-process race needs a real fix.

---

## ExchangePollJob — circuit on persistent MalformedResponse
**Priority:** P3
**Captured:** /ship adversarial review on PR #9

A persistently-broken exchange contract (e.g. Binance changes JSON
shape) results in infinite ERROR logs every 2s — the chain stays
"healthy" by ADR 0002 design. Add a counter (Redis: per-Source
malformed count, TTL = 5 min) — after N consecutive malformed responses,
mark the Source Unhealthy with a longer TTL so a human notices. Trade:
one more failure mode in the failure ladder.

---

## ExchangePollJob — TODOs from PR #9 testing specialist
**Priority:** P3
**Captured:** /ship pre-landing review on PR #9

Defensible-as-deferred coverage gaps:
- ActiveRecord::RecordInvalid path in `Tick.create!` not covered
  (currently propagates → dead set per ADR 0002 `retry: 0` design,
  but the contract isn't pinned by a spec)
- AGGREGATION_WINDOW boundary spec for the supervisor (kernel has one
  in `core_staleness_boundary_spec.rb`; symmetric supervisor test would
  prevent off-by-one regression)
- /healthz `rescue StandardError → 0` rescue path not covered
- Initializer's `after_initialize` wiring not tested directly (only
  `Aggregator::Poller.kick!` is; `kick!` is the testable seam by design)

None of these are load-bearing — `retry: 0` makes regressions visible
in Sidekiq's dead set rather than silently hidden. Adding them is a
boil-the-lake polish pass when convenient.

---

## Sidekiq queue ordering / weighting
**Priority:** P3
**Captured:** /ship adversarial review on PR #9

`config/sidekiq.yml` lists queues `[default, polling]`. Sidekiq 7+
processes queues in declaration order with some fairness (not strict
priority unless `:strict: true`). With concurrency 8 and a future
broadcast job firing on `default` every second, polling could theoretically
starve. Switch to weighted queues (`polling: 4, default: 1`) once Phase 4's
broadcast job lands and we can measure real contention.

---

## Multi-process v1 enforcement
**Priority:** P3
**Captured:** /ship adversarial review on PR #9

ADR 0002 acknowledges that two Sidekiq processes running the supervisor
simultaneously will produce duplicate chains. v1 ships with a single
worker container (docker-compose `worker: ... command: bundle exec sidekiq`).
A future `--scale worker=2` would silently break correctness. Fix: the
supervisor acquires a Postgres advisory lock at start of perform; if it
fails to acquire (another process holds it), it skips the iteration.
Cheap, no new gem.

---

## Sources::Base — cap response body size to bound memory
**Priority:** P2
**Captured:** /ship adversarial review on PR #11

`Oj.load(response.body, mode: :strict)` in every adapter parses the
response body without a size cap. A hostile or compromised endpoint
(or a buggy edge cache, or a MITM) can return a multi-GB JSON document
that exhausts the Sidekiq worker's memory before parsing fails.
Faraday's `read_timeout` (5s) bounds wall time, not bytes — a fast
attacker can stream gigabytes inside the timeout. Fix: a Faraday
middleware in `Base#build_connection` that aborts when `Content-Length`
or accumulated bytes exceed a limit (e.g. 1 MB — exchange tickers are
~1 KB). Affects all three adapters; one fix at the Base level covers
all of them.

---

## Sources::Binance, Sources::Coinbase — apply Kraken's non-finite + truncation hardening
**Priority:** P3
**Captured:** /ship adversarial review on PR #11

Kraken's parser now rejects `BigDecimal("NaN")` / `BigDecimal("Infinity")`
and a zero-or-negative price (would otherwise propagate as poison through
the kernel's MAD outlier and weighted-mean math). It also truncates
upstream-controlled strings (`error[0]`, `Date` header, `inspect` of bad
fields) to 256 chars before interpolating into `MalformedResponse` —
preventing a hostile/buggy upstream from log-bombing Rails logs. The
same hardening should land in `binance.rb` and `coinbase.rb` for
symmetry. Each is ~10 lines of code plus 4 specs. Bundle into one PR
since the change is identical in shape.
