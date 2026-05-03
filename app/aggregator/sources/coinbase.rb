require "oj"
require "time"

module Aggregator
  module Sources
    # Coinbase adapter (Advanced Trade — public market data).
    #
    # Endpoint: GET https://api.coinbase.com/api/v3/brokerage/market/products/<NATIVE>
    #
    # The trade-offs around endpoint choice, quote-volume computation, and
    # `source_ts` sourcing are recorded in
    # docs/adr/0003-coinbase-source-decisions.md. The short version:
    #   - public `/market/products/...` (unauth), not `/products/.../ticker` (auth)
    #   - quote_volume_24h = volume_24h × price (response carries base volume)
    #   - source_ts comes from the HTTP `Date` response header — Coinbase's
    #     payload has no server timestamp, and silently falling back to
    #     Time.now.utc would defeat the staleness SLO for this Source
    #
    # Rate-limit budget
    # ─────────────────
    # Coinbase Advanced Trade public market endpoints: ~30 req/s per IP.
    # Polling at 2s = 0.5 req/s — under 2% of budget.
    #
    # Symbol mapping
    # ──────────────
    # Coinbase product_ids are already in canonical form (`BTC-USD`). The
    # SYMBOL_MAP is identity, kept for symmetry with adapters that DO
    # translate (Binance's BTCUSDT, future Kraken's XXBTZUSD) — so the
    # "every adapter handles its own translation" pattern is visible at
    # the same place in every file.
    class Coinbase < Base
      BASE_URL = "https://api.coinbase.com".freeze
      ENDPOINT_PREFIX = "/api/v3/brokerage/market/products".freeze

      SYMBOL_MAP = {
        "BTC-USD" => "BTC-USD"
      }.freeze

      def name
        "coinbase"
      end

      private

      def base_url
        BASE_URL
      end

      def request(canonical_pair)
        native = SYMBOL_MAP.fetch(canonical_pair) do
          raise ArgumentError, "coinbase does not support pair: #{canonical_pair.inspect}"
        end
        @http.get("#{ENDPOINT_PREFIX}/#{native}")
      end

      def parse_payload(response, canonical_pair)
        payload = Oj.load(response.body, mode: :strict)
        raise MalformedResponse, "coinbase: response body was not a JSON object" unless payload.is_a?(Hash)

        # Fetch every required field up front so missing-field errors surface
        # before any value-shape errors. Mirrors the Binance adapter's pattern
        # (see binance.rb) so operators see consistent error messages across
        # adapters.
        price       = payload.fetch("price")
        volume_24h  = payload.fetch("volume_24h")

        price_bd      = BigDecimal(price)
        volume_24h_bd = BigDecimal(volume_24h)

        Aggregator::Tick.new(
          exchange:         name,
          pair:             canonical_pair,
          price:            price_bd,
          quote_volume_24h: volume_24h_bd * price_bd,
          source_ts:        parse_date_header(response),
          ingested_ts:      Time.now.utc
        )
      rescue KeyError => e
        raise MalformedResponse, "coinbase: missing field #{e.key.inspect}"
      rescue ArgumentError, TypeError => e
        # BigDecimal("not-a-number") raises ArgumentError; BigDecimal(nil) raises
        # TypeError. We deliberately do NOT catch NoMethodError — that would
        # swallow programmer typos as "malformed payload". Anything outside the
        # explicit type checks above is a real bug and should propagate.
        raise MalformedResponse, "coinbase: malformed payload — #{e.message}"
      end

      # Coinbase's response payload has no server timestamp. We anchor
      # `source_ts` to the HTTP `Date` response header — second precision is
      # within the staleness SLO budget. Absent or unparseable header is a
      # MalformedResponse, not a silent fallback to Time.now.utc, because
      # falling back would mean Coinbase ticks are never rejected by the
      # 10s staleness SLO and the kernel is silently broken for this Source.
      def parse_date_header(response)
        raw = response.headers["Date"] || response.headers["date"]
        raise MalformedResponse, "coinbase: missing Date response header" if raw.nil?

        Time.httpdate(raw).utc
      rescue ArgumentError => e
        raise MalformedResponse, "coinbase: unparseable Date header #{raw.inspect} — #{e.message}"
      end
    end
  end
end
