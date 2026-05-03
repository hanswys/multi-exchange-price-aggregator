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

| Canonical pair | Binance              | Coinbase   |
|----------------|----------------------|------------|
| `BTC-USD`      | `BTCUSDT` (ticker)   | `BTC-USD`  |

Notes:

- **Binance** has no native `BTC/USD` market; we map canonical `BTC-USD` to
  `BTCUSDT` and treat USD/USDT as the same quote currency for v1. USDT depeg
  risk is acknowledged (see `CONTEXT.md`, "USD-quote convention").
- **Coinbase** product IDs are already canonical; the adapter's `SYMBOL_MAP`
  is identity but kept for symmetry with adapters that translate (so the
  pattern is in the same place in every file).
- See `docs/adr/0003-coinbase-source-decisions.md` for why the Coinbase
  adapter reads `source_ts` from the HTTP `Date` header rather than the JSON
  body — the only such asymmetry across Sources.
