require "oj"

module Aggregator
  module Sources
    # Binance adapter.
    #
    # Endpoint: GET https://api.binance.com/api/v3/ticker/24hr?symbol=<NATIVE>
    #
    # Rate-limit budget
    # ─────────────────
    # Binance public budget: 1200 weight/min per IP.
    # /ticker/24hr with `symbol=` set: weight 2 per request.
    # Polling at 2s = 30 req/min × 2 = 60 weight/min — 5% of budget.
    # Headroom is ~20×; a 5× burst is safe.
    #
    # Symbol mapping
    # ──────────────
    # Canonical BTC-USD → Binance BTCUSDT (USD/USDT treated as same quote
    # currency for v1; see CONTEXT.md USD-quote convention).
    class Binance < Base
      BASE_URL = "https://api.binance.com".freeze
      ENDPOINT = "/api/v3/ticker/24hr".freeze

      SYMBOL_MAP = {
        "BTC-USD" => "BTCUSDT"
      }.freeze

      def name
        "binance"
      end

      private

      def base_url
        BASE_URL
      end

      def request(canonical_pair)
        native = SYMBOL_MAP.fetch(canonical_pair) do
          raise ArgumentError, "binance does not support pair: #{canonical_pair.inspect}"
        end
        @http.get(ENDPOINT, { symbol: native })
      end

      def parse_payload(body, canonical_pair)
        payload = Oj.load(body, mode: :strict)
        raise MalformedResponse, "binance: response body was not a JSON object" unless payload.is_a?(Hash)

        # Fetch every required field up front so missing-field errors surface
        # before any value-shape errors. This keeps "missing lastPrice" and
        # "lastPrice is garbage" as distinct failure messages for operators.
        last_price       = payload.fetch("lastPrice")
        quote_volume_24h = payload.fetch("quoteVolume")
        close_time_ms    = payload.fetch("closeTime")

        unless close_time_ms.is_a?(Integer)
          raise MalformedResponse, "binance: closeTime is not an integer (#{close_time_ms.inspect})"
        end

        Aggregator::Tick.new(
          exchange:         name,
          pair:             canonical_pair,
          price:            BigDecimal(last_price),
          quote_volume_24h: BigDecimal(quote_volume_24h),
          source_ts:        Time.at(0, close_time_ms, :millisecond).utc,
          ingested_ts:      Time.now.utc
        )
      rescue KeyError => e
        raise MalformedResponse, "binance: missing field #{e.key.inspect}"
      rescue ArgumentError, TypeError => e
        # BigDecimal("not-a-number") raises ArgumentError; BigDecimal(nil) raises
        # TypeError. We deliberately do NOT catch NoMethodError — that would
        # swallow programmer typos as "malformed payload". Anything outside the
        # explicit type checks above is a real bug and should propagate.
        raise MalformedResponse, "binance: malformed payload — #{e.message}"
      end
    end
  end
end
