# Missing-source `unreachable` rejections are injected by the controller, not the kernel

**Status**: accepted (2026-05-03)

## Context

`Aggregator::Core.compute(ticks:)` only knows about Ticks it is given. If a
Source in `Aggregator::Sources::REGISTRY` produced no Tick within the
aggregation window, the kernel cannot generate a rejection row for it —
there is no input to reject.

The `/price/:pair` response schema (design doc and PR #8 acceptance) requires
that Sources absent from a healthy aggregate appear in `sources_rejected`
with `reason: "unreachable"`. The 503 `insufficient_sources` envelope has
the same requirement. So the JSON output needs missing-source rows that
the kernel will not produce.

Two places this synthesis can live:

- **(A)** Controller-level glue. `Api::V1::PricesController` computes
  `missing = REGISTRY − seen_exchanges` from the loaded Ticks and appends
  the rows to `sources_rejected` on both the success render and the
  `InsufficientSources` rescue.
- **(B)** Kernel-aware. `Core.compute(ticks:, expected_sources:)` generates
  the rows itself.

## Decision

(A) — controller injects missing-source rejections after the kernel returns,
and onto the 503 envelope before render. The kernel stays registry-blind.

## Considered Options

- **(B) was tempting** because the kernel is already the source of truth for
  *which kinds* of rejection exist (`stale`, `outlier`, `unreachable`), and
  pushing the missing-source case in would centralize the schema. It would
  also fix one latent classification bug: `confidence_for` checks
  `rejections.any? { reason == 'outlier' }`, which today returns
  `degraded_outlier` for a "1 outlier + 1 missing" case (4-Source future)
  even though `degraded_unreachable` is also true. With v1's 3-Source
  REGISTRY this can't actually happen — at most one of {used, kernel-rejected,
  missing} per Source — so the bug is dormant.
- (A) keeps the kernel a pure function of its inputs, which makes the
  replay spec story cleaner: a fixture file is sufficient to characterize
  the kernel without a registry list bolted onto it.

## Consequences

- A future reader will see `Aggregate#sources_rejected` populated with
  `unreachable` rows in the JSON response that don't appear in the
  kernel's `Aggregate` value object. CONTEXT.md flags this under
  "Missing-source rejection."
- If/when a 4th Source lands, revisit: the dormant `confidence_for`
  classification gap becomes real. Either move synthesis into the kernel
  at that point (superseding this ADR) or recompute confidence in the
  controller after injection.
- The controller's `seen_exchanges` set is computed from the *loaded* Ticks
  (pre-kernel), not the *kept* Ticks (post-kernel) — so a Source whose only
  Tick was stale gets exactly one rejection (the kernel's `stale`), not two.
