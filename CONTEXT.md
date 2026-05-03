# Multi-Exchange Price Aggregator

A Rails service that polls multiple cryptocurrency exchanges, normalizes their
responses, and exposes a consensus price weighted by 24h quote volume. The
project's thesis is that the hard part is correctness under failure (clock
skew, stale data, outliers, divergent quotes), not throughput — so the language
below leans into that.

## Language

### Sources and ticks

**Source**:
An exchange we pull prices from. Each Source has its own adapter under
`Aggregator::Sources::` and is referenced by a stable lowercase name
(`binance`, `coinbase`, `kraken`).
_Avoid_: exchange (when speaking about the adapter), feed, provider.

**Tick**:
A single price observation from one Source at a moment in time, with the
24h quote volume the Source was reporting at that moment. The kernel value
object `Aggregator::Tick`.
_Avoid_: quote, sample, observation, reading.

**Source-native symbol**:
The string a Source uses for a market in its own API (`BTCUSDT` on Binance,
`XXBTZUSD` on Kraken, `BTC-USD` on Coinbase). Lives only inside the adapter.
_Avoid_: raw symbol, exchange symbol, ticker.

**Canonical pair**:
The repo-wide name for a market (`BTC-USD`). The only pair name that
crosses adapter boundaries — the kernel, the API, the dashboard, and Redis
keys all use it.
_Avoid_: pair (alone — qualify as canonical when ambiguous), product, market.

**Supported pair set**:
The list of Canonical pairs the v1 service answers for. Lives in
`Aggregator::Sources::CANONICAL_PAIRS` (v1: `["BTC-USD"]`). Used by
`Api::V1::PricesController` to gate `/price/:pair` requests; an unknown
pair returns 404 `unknown_pair` with `supported_pairs` echoed in the
envelope.
_Avoid_: allowed pairs, valid pairs, whitelist.

**USD-quote convention**:
For the canonical pair `BTC-USD`, USD and USDT are treated as the same quote
currency. Binance's `BTCUSDT` maps to canonical `BTC-USD`. Documented as a
deliberate v1 simplification; USDT depeg risk acknowledged.

### Source health

**Unhealthy**:
A Source's state when its circuit is open — three consecutive fetch attempts
have failed and we are not making further requests for `UNHEALTHY_TTL`
(30s). Tracked by the existence of a Redis key per Source.
_Avoid_: down, broken, tripped, open-circuit, dead.

**Unreachable** (event, not state):
A single fetch attempt has failed all retries. Distinct from Unhealthy:
Unreachable is the *event* that, on its third occurrence in a window, flips
the Source to Unhealthy. The kernel's rejection reason for a missing Source
is also `unreachable` — a Source that's Unhealthy at aggregation time
contributes an `unreachable` rejection, not an `unhealthy` one. The
distinction matters to the adapter; it does not matter to the kernel.

### Polling

**Polling chain**:
The recurring per-Source sequence of `ExchangePollJob` runs. Each run
fetches one Tick, persists it, and self-reschedules the next run via
`perform_in(POLLING_INTERVAL)`. One Polling chain per Source.
_Avoid_: poller, poll loop, polling job (singular — there are many).

**Killing the chain** is the act of skipping the self-reschedule when a
Source raises `Unhealthy` or `Unreachable`. A killed chain is revived by
the **Supervisor** (see below); the chain is *not* killed on
`MalformedResponse` (Source is reachable, payload was bad — log and
continue at the next interval).

**Supervisor**:
A separate job (`PollerSupervisorJob`) running once per minute. For each
known Source, it re-enqueues an `ExchangePollJob` if the chain is dead
*and* the Source is not currently Unhealthy. "Dead" is detected as
"latest Tick for this Source is older than `UNHEALTHY_TTL`."
_Avoid_: watchdog, monitor, restarter.

### Aggregation

**Aggregate**:
The output of `Aggregator::Core.compute` — a consensus price across Sources
for one canonical pair, plus the list of which Sources contributed and which
were rejected and why. The value object `Aggregator::Aggregate`.
_Avoid_: result, snapshot, summary.

**Confidence**:
A label on an Aggregate describing how trustworthy the consensus is.
Enumerated: `ok` (all Sources contributed), `degraded_outlier` (one Source
rejected as an outlier), `degraded_unreachable` (one Source absent or
Unhealthy). Below `MIN_SOURCES` healthy contributors the Aggregate is not
produced — `Aggregator::InsufficientSources` is raised instead.

**Rejection**:
A structured reason a Source did not contribute to a given Aggregate.
Reasons: `stale`, `outlier`, `unreachable`. Lives in
`Aggregate#sources_rejected`.

**Missing-source rejection**:
An `unreachable` Rejection synthesized **outside** the kernel for a
Source in `Aggregator::Sources::REGISTRY` that produced no Tick within
the aggregation window. The kernel only rejects Ticks it sees; the API
controller is responsible for computing `REGISTRY − seen_exchanges` and
appending the missing-source rows to the JSON `sources_rejected` array
on both the 200 success path and the 503 `insufficient_sources` rescue.
This keeps `Aggregator::Core` registry-blind.

## Relationships

- A **Source** produces zero or more **Ticks** per polling cycle.
- An **Aggregate** is computed from the most recent **Tick** per **Source**
  within the aggregation window for one **Canonical pair**.
- A **Source** is either healthy or **Unhealthy**. An **Unhealthy** Source
  appears in **Aggregate#sources_rejected** with reason `unreachable`.
- **Source-native symbols** are translated to **Canonical pairs** at the
  adapter boundary; nothing outside `Aggregator::Sources::` knows them.

## Example dialogue

> **Reviewer:** "When Binance is unhealthy and we hit `/price/BTC-USD`, what
> shows up in the response?"
>
> **Hans:** "An entry in `sources_rejected` with `exchange: "binance"`,
> `reason: "unreachable"`. The kernel doesn't distinguish between a Source
> that timed out once during this window and one whose circuit is open —
> both are absent Ticks from its perspective. The adapter knows the
> difference; the API surface intentionally doesn't."

### API surface

**`/price/:pair`**:
The single read-only JSON endpoint exposed by `Api::V1::PricesController`.
Returns 200 with an `Aggregate` envelope on success, 404 `unknown_pair`
for a pair not in the Supported pair set, and 503 `insufficient_sources`
when fewer than `MIN_SOURCES` healthy contributors are available. The
controller inherits from `ActionController::API` (not `ApplicationController`)
to bypass the dashboard's `allow_browser :modern` filter and keep the
middleware stack appropriate for a public read API. CORS is wide-open
(`origins '*'`, `methods: [:get]`, `resource '/price/*'`); responses are
`Cache-Control: no-store` because the body carries `as_of` and any cache
duration would make the response lie about its own timestamp.

## Flagged ambiguities

- "Circuit open" vs "unhealthy" — resolved: the state is **Unhealthy**.
  "Circuit breaker" is the mechanism and stays in code/comments only.
- "Pair" alone is ambiguous between **Canonical pair** and
  **Source-native symbol**. Always qualify when both are in scope (e.g.
  inside an adapter that translates between them).
- "Unreachable" overloads two ideas: a single failed fetch attempt, and
  the kernel's rejection reason. Acceptable overlap because the second is
  a generalization of the first; flagged here so future readers don't
  introduce a third meaning.
