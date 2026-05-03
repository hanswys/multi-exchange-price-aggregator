# Broadcast chain: cadence, idempotency, and the truth-telling rule

**Status**: accepted (2026-05-04)

## Context

Phase 4 ships the live dashboard via a `BroadcastTickJob` that pushes Turbo
Stream updates to subscribed clients. ADR 0002 already pre-registered the
shape ("self-reschedule + `retry: 0`, no supervisor needed — broadcast is a
read job"). Filling in the rest required four decisions that are all
surprising-without-context.

## Decisions

### 1. Decoupled cadence; idempotency via Redis sentinel, not supervisor

The Broadcast chain runs at `BROADCAST_INTERVAL` (1s), independent of
`POLLING_INTERVAL` (2s). Three Sources polling at 2s with offset would
otherwise produce a stutter pattern in the dashboard; one chain at 1s
gives a steady metronome regardless of polling phase.

There is **no supervisor** for the Broadcast chain (per ADR 0002), but
there is also no "exactly one chain in flight" guarantee from
`Sidekiq.server?` alone — a Sidekiq restart while the previous chain's
`perform_in(1.second)` is still in the scheduled set would result in two
chains, then four after the next restart. Harmless for correctness
(broadcast is idempotent at the channel level) but visible in the
Sidekiq UI and wasteful at scale.

Mitigation: a Redis sentinel `broadcaster:in_flight` set with
`SET ... NX EX 3` at the start of each `perform`. The boot initializer
and the self-reschedule both gate on this sentinel. Three-second TTL is
the smallest value that survives one missed cycle without permanently
deadlocking a dead chain. No supervisor, no `sidekiq-cron`, no
in-process locks — one Redis key.

### 2. The Consensus partial subsumes `_state_ok` and `_state_partial`

Originally `app/views/dashboard/` had separate `_state_ok.html.erb` and
`_state_partial.html.erb`, picked by the controller from `@state`. That
shape doesn't survive broadcasting: a chain that broadcasts the wrong
partial on a confidence transition (`ok → degraded_outlier` mid-stream)
shows stale badge classes, or requires the chain to know the prior
state. Both wrong.

`_consensus.html.erb` is one partial that branches on `agg.confidence`
internally. Used both by the initial server render and by every
broadcast. The deleted `_state_ok` and `_state_partial` had no other
callers.

### 3. InsufficientSources broadcasts `_state_error`; never skips

The plan-as-written said "if compute raises `InsufficientSources`, skip
broadcasting so the existing 503 state remains rendered." That rule is
wrong for the common case: a page rendered as `:ok` whose Sources
*subsequently* fail would freeze on the last healthy price with no
indication anything is wrong. The dashboard's correctness thesis is
"Things That Will Lie To You" — letting the dashboard itself lie is the
worst possible failure mode.

The Broadcast chain rescues `InsufficientSources` and broadcasts
`_state_error.html.erb` (with last-good-price locals) to the same
`consensus_hero` target. The 503 state is reachable both at
request-time render and mid-session; both paths surface the same
partial. The chain self-reschedules on the rescue path too — recovery
to `:ok` happens on the next cycle without a chain restart.

### 4. Dev cable flips from `async` to Redis

Under `docker compose up`, `web` and `worker` are separate processes.
The Action Cable `async` adapter is in-process only — a broadcast from
the worker never reaches a client connected to the web. The default
`cable.yml` shipped by Rails would silently fail in dev for any
multi-process setup.

Dev now uses the Redis adapter with the same `REDIS_URL` as Sidekiq,
distinct `channel_prefix`. `bin/dev` (Foreman, single-host) also works
through Redis without behavior change. Test stays on `:test`; system
specs that need real fan-out flip to `:async` per-spec (Capybara's app
server is in-process, async is correct there).

## Considered alternatives

- **Supervisor for the Broadcast chain.** Rejected: broadcast is
  idempotent and stateless. A supervisor adds another job to reason
  about for no correctness gain. The Redis sentinel is one key.
- **Skipping the broadcast on `InsufficientSources`** (the literal
  plan). Rejected: produces a lying dashboard on the most damaging
  transition.
- **Keeping `_state_ok` / `_state_partial` separate, with the
  Broadcast chain selecting the partial.** Rejected: forces the chain
  to encode view-layer state-machine knowledge.
- **`broadcast_replace_to`** (replaces the outer element). Rejected
  for `update_to`: replace would destroy and recreate
  `consensus_hero`, killing the Stimulus flash controller's reference
  to "previous price." Update keeps the outer node and swaps
  innerHTML, so the controller persists across broadcasts.

## Consequences

- The Broadcast chain has three exit paths from `perform`: success
  (broadcast Aggregate), `InsufficientSources` (broadcast error
  partial), unrescued exception (lands in the dead set, recovered on
  next Sidekiq restart). All three self-reschedule the next run
  *except* the unrescued path.
- `_consensus.html.erb` is the only partial broadcast on the happy
  path. Adding new fields (e.g. confidence sub-labels, divergence
  scores in Phase 2) means editing one file.
- The Stimulus flash controller attaches to `consensus_hero` (which
  is **not** replaced) and observes `turbo:before-stream-render` to
  diff old vs new price. This is structurally tied to the choice of
  `update_to` over `replace_to` — switching the broadcast action
  would require restructuring the controller.
- `cable.yml` dev → Redis means `bin/dev` now requires Redis running
  locally, same as Sidekiq does. README's "Without Docker" quickstart
  must list Redis as a prereq (it already does, for Sidekiq).
