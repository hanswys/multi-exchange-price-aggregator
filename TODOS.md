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
