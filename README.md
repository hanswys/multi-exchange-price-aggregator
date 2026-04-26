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
