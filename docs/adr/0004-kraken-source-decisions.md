# Kraken adapter: error envelope, native-symbol round-trip, computed quote volume, header-anchored `source_ts`

**Status**: accepted (2026-05-03)

## Context

Phase 3 ships the third exchange adapter (`Aggregator::Sources::Kraken`).
Reaching for `GET /0/public/Ticker?pair=XXBTZUSD` surfaces four coupled
decisions that did not arise — at least not all together — for Binance or
Coinbase:

1. Kraken's public REST never returns 4xx for application-level errors. A
   bad pair, a transient outage, or a rate-limit rebuke all return HTTP 200
   with `{"error": ["E…:…"], "result": {}}`. The adapter has to recognise
   the envelope.
2. The `result` object is keyed by the *Kraken-native symbol the request
   asked for* (e.g. `result["XXBTZUSD"]`). The mapping owned by
   `SYMBOL_MAP` is therefore load-bearing for two things — the request
   param AND the response-key lookup — not just one.
3. Like Coinbase, Kraken's ticker payload has no body-level server
   timestamp, so `source_ts` has to come from somewhere outside the JSON
   body or the Source is silently exempt from the staleness SLO.
4. Unlike Coinbase, Kraken exposes a true 24h VWAP (`p[1]`) alongside the
   24h base volume (`v[1]`), so there is a real choice between
   `v[1] × c[0]` (consistent with Coinbase) and `v[1] × p[1]` (the
   most-authoritative quote-volume figure Kraken offers).

Each of these is hard to reverse — cassette shape, parser code, and spec
assertions are coupled to all four — and surprising to a future reader
scanning the adapter file (e.g. "why a different volume formula than
Coinbase?", "why does this duplicate Coinbase's date-header helper?").
They are recorded together because they all stem from the same root: the
shape of Kraken's public ticker response differs from both prior Sources
in ways that propagate through the parser.

## Decision

### Error envelope: 200 + non-empty `error` → `MalformedResponse`

A 200 response whose body has a non-empty `error` array is raised as
`Aggregator::Sources::MalformedResponse`, with the first error string
interpolated into the message — e.g.
`kraken: API error — EQuery:Unknown asset pair`.

Rationale: `MalformedResponse` already carries the right semantics per
ADR 0001 and CONTEXT.md — Source is reachable, payload was bad, do not
retry, do not kill the chain. Kraken's `EService:Busy` and
`EAPI:Rate limit exceeded` cases share that profile: the next polling
interval is the right place to try again, not a tight retry loop. A
dedicated `Aggregator::Sources::ApiError` would split the failure
ladder for one Source's quirk and earn its weight in no other adapter.

Consequence: a sustained Kraken outage manifests as repeated
`MalformedResponse` log lines until the chain's *latest Tick* ages past
`AGGREGATION_WINDOW`, at which point the Source is absent from the
Aggregate with reason `unreachable`. The chain itself stays alive (per
ADR 0002). If this turns out to mask a real Kraken-side incident, the
TODO `ExchangePollJob — circuit on persistent MalformedResponse` is the
escalation path — same fix, applied uniformly across Sources.

### Result lookup: by sent native symbol, not `.values.first`

The parser fetches the inner ticker block as
`result.fetch(SYMBOL_MAP.fetch(canonical_pair))` — i.e. it looks up the
key it just *sent*. Missing key raises `MalformedResponse`.

The tolerant alternative (`result.values.first`) would silently absorb a
hypothetical Kraken-side rewrite (e.g. responding under the `XBTUSD`
altname instead of the X/Z-prefixed `XXBTZUSD`). We want a loud failure
in that case for two reasons:

1. The X/Z prefix convention is the headline reason this Source is in
   the lineup — its visible enforcement at parse time is the test that
   asserts the README's "Kraken's quirky symbols" claim is real, not
   nominal.
2. A silent altname rewrite would change `result`'s key without changing
   the rest of the response shape. `.values.first` would parse it
   successfully and the kernel would never know we had stopped seeing
   the symbol we thought we were polling.

The cost: one extra spec case (`kraken_parse_spec.rb` →
"raises MalformedResponse if Kraken responds under a different key") and
the SYMBOL_MAP becomes load-bearing for the request param AND the
response-key lookup. That coupling is itself the point — it's the
in-file reason a shared `SymbolMapper` is the wrong shape, which the
README's note formalises.

### `source_ts` from HTTP `Date` response header

Same approach as Coinbase (ADR 0003), same reasoning: the alternative is
silently falling back to `Time.now.utc`, which means a Kraken snapshot
that took 30s to reach us would never be rejected by the 10s staleness
SLO and the kernel would be silently broken for one Source. Second
precision is acceptable — the SLO budget was set with NTP-grade host
clocks in mind.

A separate call to `/0/public/Time` to anchor `source_ts` to Kraken's
own server clock was rejected: it doubles per-poll rate-budget
consumption against a 1 req/s soft cap, and it adds a coupled-call
failure mode (Time succeeds, Ticker fails — or vice versa) that the
adapter would have to reason about.

### Helper duplication: `parse_date_header` copied, not extracted

`parse_date_header` in `kraken.rb` is byte-identical to the helper in
`coinbase.rb`. It is *deliberately* copied rather than extracted to
`Aggregator::Sources::Base`.

Reasoning:

- The "no shared `SymbolMapper`" stance the README defends in this same
  PR rests on per-adapter readability ("each adapter's normalisation
  lives next to the rest of the adapter that needs it"). Extracting
  `parse_date_header` to `Base` on the same PR sends the opposite signal.
- `Base` today is HTTP / retry / circuit-breaker scaffolding only — it
  knows nothing about response parsing. Adding a parsing helper drifts
  its responsibility.
- Two call sites is below the rule-of-three threshold. If a fourth
  Source ever needs Date-header anchoring, that is the moment to
  extract — and by then we will know whether the helper should also
  cope with e.g. `Last-Modified` fallback or millisecond-precision
  alternatives.

Cost: 7 lines of duplication, and a parser-rule change has to be made
in two places. Worth it for the readability stance.

### `quote_volume_24h = v[1] × p[1]`

Computed at parse time as `BigDecimal(v[1]) * BigDecimal(p[1])`.

Kraken returns:

- `v` = `[base_volume_today, base_volume_24h]`
- `p` = `[vwap_today, vwap_24h]`

The 24h-VWAP × 24h-base-volume product is by definition the actual
quote-currency volume that traded in the window — *the* value the
kernel's "weight by venue activity" formula wants.

The alternative `v[1] × c[0]` (last-price × base-volume, same shape as
Coinbase) was rejected: Coinbase has no VWAP field and is using
last-price as a snapshot proxy because nothing better is exposed.
Kraken *does* expose the better number, and the kernel's MAD outlier
rejection runs against `price` (not against weight), so weight precision
moves the consensus by less than the volatility floor under any normal
conditions — there is no correctness reason to under-use Kraken's
better data for symmetry with Coinbase's worse data.

The asymmetry across the three Sources — Binance uses native
`quoteVolume`, Coinbase computes `volume_24h × price`, Kraken computes
`v[1] × p[1]` — is "each adapter exposes the most authoritative
quote-volume figure that exchange offers." Documented here so a
reviewer reads it as a deliberate choice rather than as inconsistency.

### Hardening: truncate upstream-controlled strings; reject non-finite numerics

Two adversarial-review findings folded into the parser before landing:

1. **Truncate upstream-controlled strings before interpolating into
   exception messages.** The Kraken-controlled `error[0]` string, the
   `Date` response header, and the `c`/`v`/`p` array `inspect` output
   are all capped at 256 characters before being woven into a
   `MalformedResponse`. A hostile or buggy upstream could otherwise
   echo a multi-MB string into Rails logs and the error tracker on
   every poll.

2. **Reject non-finite and non-positive numerics.** `BigDecimal("NaN")`,
   `BigDecimal("Infinity")`, and `BigDecimal("-Infinity")` parse
   without raising and would otherwise propagate through the kernel's
   MAD outlier rejection and weighted-mean math as `NaN`, silently
   poisoning the consensus across all Sources at once. The parser
   raises `MalformedResponse` on any non-finite value and on a
   zero-or-negative price (no real BTC market quotes 0). Zero
   quote-volume is allowed — the kernel already handles it (see
   `core_zero_volume_spec.rb`).

Both hardenings are Kraken-only in this PR; siblings get the same
treatment as a follow-up (tracked in TODOS.md).

## Consequences

- The Kraken VCR cassette must include the `Date` response header
  verbatim — `kraken_spec.rb` asserts on `tick.source_ts` and breaks if
  the cassette is recorded without that header. (Same constraint as
  Coinbase's cassette per ADR 0003.)
- The cassette's `result` payload must use the X/Z-prefixed key
  `XXBTZUSD` — `kraken_parse_spec.rb` includes a regression covering
  the altname-rewrite case, but the happy-path contract spec depends
  on the prefixed key.
- A future ETH-USD extension on Kraken extends `SYMBOL_MAP` with
  `"ETH-USD" => "XETHZUSD"` and reuses the same parser unchanged.
- A future fourth Source needing Date-header anchoring is the trigger
  to extract `parse_date_header` to `Aggregator::Sources::Base`. Update
  this ADR (Status: superseded) when that happens.
- The volume-formula divergence across the three Sources is *not* a
  bug — it is a documented choice. A reviewer who flags it as
  inconsistency should be pointed here.
