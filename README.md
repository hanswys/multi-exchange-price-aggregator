# Multi-Exchange Price Aggregator

A volume-weighted price oracle that polls multiple crypto exchanges, rejects
stale and outlier ticks via a deterministic correctness kernel, and exposes a
consensus VWAP through a JSON API and live Hotwire dashboard.

## Quickstart

```sh
cp .env.example .env       # dev-only credentials for the local containers
docker compose up
curl localhost:3000/healthz
# => {"status":"ok","db":"ok","redis":"ok","sources_healthy":0}
```

`.env` is gitignored. `docker-compose.yml` requires `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_DB`, `DATABASE_USER`, and `DATABASE_PASSWORD` to
be set — Compose will refuse to start otherwise.

See `ROADMAP.md` for the implementation sequence and `TODOS.md` for deferred
work.

## Sources

Each Source has its own adapter under `app/aggregator/sources/` and translates
its own native symbols to the canonical pair. No cross-adapter symbol table —
the translation is owned by the adapter that needs it.

| Canonical pair | Binance              | Coinbase   | Kraken      |
|----------------|----------------------|------------|-------------|
| `BTC-USD`      | `BTCUSDT` (ticker)   | `BTC-USD`  | `XXBTZUSD`  |

Notes:

- **Binance** has no native `BTC/USD` market; we map canonical `BTC-USD` to
  `BTCUSDT` and treat USD/USDT as the same quote currency for v1. USDT depeg
  risk is acknowledged (see `CONTEXT.md`, "USD-quote convention").
- **Coinbase** product IDs are already canonical; the adapter's `SYMBOL_MAP`
  is identity but kept for symmetry with adapters that translate (so the
  pattern is in the same place in every file). See
  `docs/adr/0003-coinbase-source-decisions.md` for why the Coinbase adapter
  reads `source_ts` from the HTTP `Date` header rather than the JSON body.
- **Kraken** uses the legacy X/Z asset-prefix convention: BTC is `XXBT`, USD
  is `ZUSD`, joined as `XXBTZUSD`. The same string is the request param
  *and* the key in the response's `result` hash, so the adapter looks up the
  result block by it (rather than `result.values.first`) — a defensive
  assertion that the API echoed back what we asked for. Kraken also signals
  application-level errors as a non-empty `error` array on a 200 response,
  which the adapter raises as `MalformedResponse`. See
  `docs/adr/0004-kraken-source-decisions.md` for the four coupled decisions
  (error envelope, native-symbol round-trip, header-anchored `source_ts`,
  computed quote volume from `v[1] × p[1]`).
- **Why no shared `SymbolMapper`?** Each adapter's symbol translation is
  paired with response-shape decisions a central table can't carry —
  Kraken keys its `result` hash by the native symbol it received, Coinbase
  interpolates the canonical pair into a URL path, Binance sends it as a
  query param. Splitting "what this exchange calls `BTC-USD`" away from
  "how to read it back" would put each adapter's two halves in different
  files. At three Sources, one file per Source reads better than a shared
  dictionary. Revisit if a fourth lookalike Source lands.
