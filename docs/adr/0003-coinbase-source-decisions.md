# Coinbase adapter: public market endpoint, computed quote volume, header-anchored `source_ts`

**Status**: accepted (2026-05-03)

## Context

Phase 3 ships the second exchange adapter (`Aggregator::Sources::Coinbase`).
The original design doc named `GET /api/v3/brokerage/products/BTC-USD/ticker`
as the endpoint. Reaching for that exact URL surfaces three coupled decisions
that did not arise for Binance:

1. Endpoints under `/api/v3/brokerage/products/...` (without `/market/`) are
   part of Coinbase Advanced Trade's *authenticated* surface. They require a
   CDP API key + per-request signed JWT. A portfolio repo whose Quickstart is
   `docker compose up` cannot ship credentials, and adding "register a
   Coinbase developer account" to the README actively damages the demo.
2. The named `/ticker` endpoint returns *recent trades* — not a 24h
   snapshot. The kernel weights by `quote_volume_24h`, which that response
   does not carry in a single call.
3. Coinbase's product response — even the snapshot one — does **not** include
   a payload-level server timestamp the way Binance's `/ticker/24hr` exposes
   `closeTime`. So `source_ts` must come from somewhere other than the JSON
   body, or the Source must be exempt from the staleness SLO (which would
   silently defeat the kernel for one of three Sources).

Each of these decisions is hard to reverse (the cassette shape, parser, and
spec assertions are coupled to all three) and surprising to a future reader
scanning the adapter file ("why does this one read a header for the
timestamp?"). They are recorded together because they all stem from the same
root: the Advanced Trade public market endpoint has a different shape than
Binance's `/ticker/24hr`.

## Decision

### Endpoint

`GET https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD`,
unauthenticated. Coinbase documents `/api/v3/brokerage/market/...` as the
public-data sibling of the authenticated Advanced Trade surface — same API
family, no credentials, single call returns price + 24h base volume + product
status.

### `quote_volume_24h`

Computed at parse time as `BigDecimal(volume_24h) * BigDecimal(price)`.

`volume_24h` in the response is denominated in the **base** currency (BTC).
The kernel weights by quote-currency volume across Sources to give
larger/more-active venues more weight, so the value must be in USD-equivalent
units consistent with Binance's `quoteVolume` field.

The response does carry a server-computed `approximate_quote_24h_volume`
field. We do not use it. Computing the product from documented core fields
(`volume_24h`, `price`) keeps the adapter independent of optional/derived
fields Coinbase may rename or remove, and surfaces the math in the parser
where a reviewer can see exactly what we're feeding the kernel.

### `source_ts`

Parsed from the HTTP `Date` response header on the same response, normalized
to UTC. `MalformedResponse` is raised when the header is absent or
unparseable — silently falling back to `Time.now.utc` would mean a Coinbase
snapshot that took 30s to reach us would never be rejected by the 10s
staleness SLO, defeating the kernel for one Source.

Second-precision is acceptable. The 10s `Constants::STALENESS_SLO` is
generous enough to absorb the sub-second clock skew this introduces; the
budget was set with NTP-grade host clocks in mind, and the `Date` header is
emitted by the same kind of clock.

This makes Coinbase the only Source whose `source_ts` originates outside the
JSON body. The asymmetry is recorded here so a future Kraken (or other)
adapter can pick the most-authoritative timestamp the Source exposes —
header, body field, or trade time — without the choice looking arbitrary.

## Consequences

- Each adapter's `parse_payload` may read from the Faraday response object
  beyond `body`. The Base class hands the full response into a parser hook
  that has access to headers; concrete adapters that only need the body
  ignore them.
- The Coinbase VCR cassette must include the `Date` response header
  verbatim — the `coinbase_spec` contract test asserts on `tick.source_ts`
  and breaks if the cassette is recorded without that header.
- A future ETH-USD or other-pair extension on Coinbase reuses the identity
  `SYMBOL_MAP` (`"BTC-USD" => "BTC-USD"`, `"ETH-USD" => "ETH-USD"`) — the
  product_id IS the canonical pair on Coinbase. The map is kept (rather
  than special-cased away) so the "every adapter handles its own symbol
  translation" pattern remains visible.
- If Coinbase ever exposes a payload-level `time` field on this endpoint,
  the adapter should switch to it — body-anchored timestamps are
  preferable to header-anchored ones because the `Date` header is the
  HTTP layer's stamp, not necessarily the snapshot generation time.
  Updating this ADR (Status: superseded by 0003a or whatever) is part of
  that change.
