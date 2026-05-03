# Source adapter `#fetch` contract: hand-rolled retry, exception-only failure surface

**Status**: accepted (2026-05-03)

## Context

Phase 2 ships the first exchange adapter (`Aggregator::Sources::Binance`). Two
shapes were on the table for the failure surface and retry mechanism, both
with real merit.

## Decision

`Aggregator::Sources::Base#fetch(canonical_pair)` returns an
`Aggregator::Tick` on success and raises one of three exceptions on failure:

- `Aggregator::Sources::Unhealthy` — circuit was already open at call time;
  no HTTP request was made.
- `Aggregator::Sources::Unreachable` — three retries exhausted (network
  errors, 5xx, or repeated 429s); the circuit is opened *before* this is
  raised.
- `Aggregator::Sources::MalformedResponse` — Source returned 200 but the
  payload could not be parsed into a Tick.

All three inherit from `Aggregator::Sources::Error`, so callers can rescue
the family or pattern-match on the specific case.

The retry loop is hand-rolled in `Base#fetch`, reading
`Aggregator::Constants::RETRY_BACKOFF_MS` (`[250, 1_000, 4_000]`) directly.
`faraday-retry` is removed from the Gemfile.

`Retry-After` on a 429 response overrides the backoff schedule for that
attempt (the loop sleeps the header's seconds, then continues with the
remaining retry budget).

## Why hand-rolled, not `faraday-retry`

The project's thesis is "I thought hard about failure modes." The retry
loop *is* the failure-mode story. Burying it inside a middleware
configuration (`request :retry, { max: 3, interval: 0.25, backoff_factor:
4 }`) means a reviewer scanning the file sees a config block and moves
on — the senior signal doesn't land.

Hand-rolling is also the only way `Constants::RETRY_BACKOFF_MS` stays the
single source of truth. `faraday-retry`'s formula (`interval ×
backoff_factor^attempt`) only happens to match `[250, 1000, 4000]` because
of arithmetic coincidence; if the constant is ever tuned to e.g.
`[300, 1500, 5000]`, the middleware would silently keep doing the old
ladder unless someone remembered to update the two scalars.

## Why exceptions, not `nil` or `Result`

The kernel's rejection list (`Aggregate#sources_rejected`) is the
*aggregate-level* surface for "Source X didn't contribute." The adapter
sits one layer below; its job is "return a Tick or tell me why you
can't." Exceptions are how Ruby idiomatically says that, and the call
sites (poll job, rake task, future supervisor) all want to discriminate
between unhealthy/unreachable/malformed — which is naturally expressed
as `rescue` clauses.

Returning `nil` would force every caller into nil-checks; a `Result`
object would be a foreign idiom in this otherwise-idiomatic Rails
codebase.

## Consequences

- The poll job (Phase 3) wraps `adapter.fetch(pair)` in
  `rescue Aggregator::Sources::Error`. It does not need to know about
  the three subclasses unless it wants to log differently per case.
- The rake task `aggregator:fetch` lets `Unhealthy` / `Unreachable` /
  `MalformedResponse` propagate to a top-level rescue that prints the
  exception class and message — so the smoke test exercises real
  failure paths.
- `RateLimited` is intentionally *not* a public exception. A 429 is an
  internal signal that the retry loop handles by sleeping
  `Retry-After`. If all three retries return 429, the loop opens the
  circuit and raises `Unreachable` like any other exhausted-retry
  case — to a reviewer of an aggregate response, "Binance was rate
  limited" and "Binance was unreachable" are the same fact.
