# Polling chain lifecycle: kill, revive, and the role of `retry: 0`

**Status**: accepted (2026-05-03)

## Context

Phase 3 ships the polling pipeline (`ExchangePollJob` + `PollerSupervisorJob`).
Sidekiq offers multiple recovery mechanisms — the retry queue, the dead set,
the scheduled set, and `sidekiq-cron` for periodic work. A naive
implementation reaches for several of them at once. That is wrong for this
codebase: two recovery paths layered on the same job produce duplicate
**Polling chains** under failure (chain dies → Sidekiq retries it AND the
supervisor enqueues a fresh one → two chains writing duplicate Ticks for
the same Source). The design below is correct-by-construction because
*exactly one* mechanism revives a dead chain.

## Decision

The polling chain has one recovery path: the **Supervisor**
(`PollerSupervisorJob`). All other Sidekiq recovery surfaces are switched
off for this pipeline.

### Failure isolation (per exception)

`Aggregator::Sources::Error` has three subclasses (see ADR 0001). Each
gets a distinct verdict in `ExchangePollJob#perform`:

| Exception           | Verdict       | Reasoning |
|---------------------|---------------|-----------|
| `Unreachable`       | **kill chain**| Circuit just opened (`UNHEALTHY_TTL` = 30s). Re-enqueueing would burn ~15 no-op jobs short-circuiting on `Unhealthy`. |
| `Unhealthy`         | **kill chain**| Means we entered `#fetch` while the circuit was already open — should be rare given the supervisor's predicate. Same waste argument. |
| `MalformedResponse` | **continue**  | Source was reachable, payload was bad. Could be a transient blip on their side or a contract drift on ours. Killing the chain on a single bad parse silences a Source for 60s; continuing surfaces the bug fast. Log loudly. |
| Unrescued `StandardError` | propagates → dead set, **no reschedule** | Anything we didn't anticipate should be visible in the Sidekiq UI, not retried into invisibility. |

### `retry: 0`

`ExchangePollJob` and `PollerSupervisorJob` both set `sidekiq_options
retry: 0`. Sidekiq's default `retry: 25` would race the supervisor — a
chain that crashes mid-perform would be re-attempted by Sidekiq's
exponential backoff *and* re-enqueued by the supervisor at the next
minute. Two parallel chains for the same Source = duplicate Tick rows
and wasted rate-limit budget. With `retry: 0`, anything unrescued lands
in the dead set immediately and the supervisor is the single recovery
path.

### Self-reschedule semantics

| Job                    | Schedules next run | Why |
|------------------------|--------------------|-----|
| `ExchangePollJob`      | At **end** of `perform` (only on healthy outcomes — Tick written, or `MalformedResponse` rescued) | If `perform` raises, the reschedule line is never reached → chain dies → supervisor catches at the next minute. |
| `PollerSupervisorJob`  | At **start** of `perform`, before any work | The supervisor has no upstream supervisor. Scheduling first means even if its body raises (and lands in the dead set), the next run is already queued. |

### Supervisor revival predicate

For each `name` in `Aggregator::Sources::REGISTRY`, enqueue an
`ExchangePollJob` if **both** are true:

1. The Source is **not** currently `Unhealthy`
   (`Aggregator::Sources::Base.unhealthy?(name)` is false).
2. The latest Tick for that Source is `nil` **or** older than
   `Aggregator::Constants::AGGREGATION_WINDOW` (10s).

The threshold is `AGGREGATION_WINDOW` — the same value the kernel uses
to decide which Ticks contribute to a consensus. A chain whose latest
Tick is past that age has failed its purpose; reviving it is correct
regardless of the proximate cause of death.

### Single liveness predicate (boot)

`config/initializers/poller.rb` does **not** enqueue chains directly. It
kicks the supervisor instead:

```ruby
Rails.application.config.after_initialize do
  PollerSupervisorJob.perform_async if Sidekiq.server?
end
```

This collapses the "is a chain in flight?" question into one place (the
supervisor's revival predicate), which is tested once and used for both
boot and steady-state.

### No `sidekiq-cron`

The supervisor self-reschedules with `perform_in(1.minute)` rather than
cron. With one recurring job in the entire app, the gem buys a YAML
file and a web UI tab. Self-rescheduling matches the polling chain
pattern — one runtime mental model, zero new dependencies. Recovery
after Redis flush or supervisor death is handled by the boot
initializer above.

## Failure modes considered

- **Sidekiq process restart.** Boot initializer re-kicks the supervisor;
  supervisor revives any dead chains. Bounded recovery: ~1 minute.
- **Redis flushed (scheduled set + retry set lost).** Same as above —
  boot initializer is the recovery path.
- **Supervisor `perform` raises.** Next run is already queued (scheduled
  at start of perform). If the next run also raises, the chain ends up
  in the dead set, recovered by next Sidekiq restart.
- **Sidekiq scheduled-poll drift.** Mitigated by setting
  `:average_scheduled_poll_interval` to 1s in `config/initializers/sidekiq.rb`,
  so `perform_in(2.seconds)` lands within ~2.5s instead of the default
  ~5-7s.
- **Two Sidekiq processes simultaneously running the supervisor.** Both
  see the same predicate state and could both enqueue a chain for the
  same Source → two chains writing duplicate Ticks for one cycle.
  Acceptable in v1 (single Sidekiq process per docker-compose). Future
  multi-process deploys would need a Redis-backed lock around the
  supervisor's enqueue step.

## Consequences

- The poll job's rescue clause is the load-bearing piece of the failure
  isolation contract. Any change to it must be paired with this ADR.
- `retry: 0` is *not* a casual setting. Reviewers tempted to "fix" it
  must read this ADR first. The Sidekiq dead set is the audit trail.
- The README's "Things That Will Lie To You" section cites this design
  directly: "the polling chain has one recovery path, on purpose."
- Phase 4's `BroadcastTickJob` follows the same pattern (self-reschedule
  + `retry: 0`) but does NOT need a supervisor — it's purely a read job
  with no side-effecting state, so a 1-minute gap on its death recovers
  on the next Sidekiq restart.
