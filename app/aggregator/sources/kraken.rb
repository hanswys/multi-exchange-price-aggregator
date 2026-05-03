require "oj"
require "time"

module Aggregator
  module Sources
    # Kraken adapter (public REST — no auth).
    #
    # Endpoint: GET https://api.kraken.com/0/public/Ticker?pair=XXBTZUSD
    #
    # The four coupled decisions in this adapter (200-with-error envelope,
    # result lookup by sent native symbol, header-anchored `source_ts`,
    # quote_volume_24h = v[1] × p[1]) are recorded in
    # docs/adr/0004-kraken-source-decisions.md.
    #
    # Rate-limit budget
    # ─────────────────
    # Kraken public-endpoint soft cap: ~1 req/s per IP. Polling at 2s
    # = 0.5 req/s — half of budget, no headroom games to play.
    #
    # Symbol mapping
    # ──────────────
    # Canonical BTC-USD → Kraken XXBTZUSD. The X-prefix on BTC and Z-prefix
    # on USD are Kraken's legacy ISO-4217-extended convention for assets
    # that share a name with a fiat currency. The same string is the
    # request param AND the key in the response's `result` hash, so the
    # SYMBOL_MAP is load-bearing for both halves of the round-trip.
    class Kraken < Base
      BASE_URL = "https://api.kraken.com".freeze
      ENDPOINT = "/0/public/Ticker".freeze

      SYMBOL_MAP = {
        "BTC-USD" => "XXBTZUSD"
      }.freeze

      def name
        "kraken"
      end

      private

      def base_url
        BASE_URL
      end

      def request(canonical_pair)
        native = SYMBOL_MAP.fetch(canonical_pair) do
          raise ArgumentError, "kraken does not support pair: #{canonical_pair.inspect}"
        end
        @http.get(ENDPOINT, { pair: native })
      end

      def parse_payload(response, canonical_pair)
        payload = Oj.load(response.body, mode: :strict)
        raise MalformedResponse, "kraken: response body was not a JSON object" unless payload.is_a?(Hash)

        # Kraken signals application-level errors in a 200 response by
        # returning a non-empty `error` array. Treat as MalformedResponse so
        # the poll job continues at the next interval (Source is reachable;
        # retrying this fetch will not help). See ADR 0004.
        #
        # Truncate the upstream-controlled error string before interpolating
        # it into the exception message — a hostile or buggy upstream could
        # otherwise log-bomb us with a multi-MB string echoed into Rails
        # logs and the error tracker.
        errors = payload["error"]
        if errors.is_a?(Array) && errors.any?
          raise MalformedResponse, "kraken: API error — #{String(errors.first)[0, 256]}"
        end

        result = payload["result"]
        raise MalformedResponse, "kraken: missing or non-object result" unless result.is_a?(Hash)

        # Look up the inner ticker block by the native symbol we sent.
        # `.values.first` would be tolerant if Kraken ever rewrote the key
        # (e.g. responding under `XBTUSD` instead of `XXBTZUSD`); we want a
        # loud failure instead, both as a defensive assertion that the API
        # echoed back what we asked for and because the X/Z prefix
        # convention is the headline reason this Source is in the lineup.
        native = SYMBOL_MAP.fetch(canonical_pair)
        ticker = result.fetch(native) do
          raise MalformedResponse, "kraken: result missing native key #{native.inspect}"
        end
        raise MalformedResponse, "kraken: ticker block for #{native} was not an object" unless ticker.is_a?(Hash)

        # Field shape: c=[last_price, last_lot_volume],
        # v=[volume_today, volume_24h] (base currency),
        # p=[vwap_today, vwap_24h]. We use the 24h pair members.
        last_price_arr = ticker.fetch("c")
        volume_arr     = ticker.fetch("v")
        vwap_arr       = ticker.fetch("p")

        last_price_str = pick_24h(last_price_arr, field: "c", index: 0)
        volume_24h_str = pick_24h(volume_arr,     field: "v", index: 1)
        vwap_24h_str   = pick_24h(vwap_arr,       field: "p", index: 1)

        price_bd      = BigDecimal(last_price_str)
        volume_24h_bd = BigDecimal(volume_24h_str)
        vwap_24h_bd   = BigDecimal(vwap_24h_str)

        # Reject non-finite numerics. `BigDecimal("NaN")`, `BigDecimal("Infinity")`,
        # and `BigDecimal("-Infinity")` parse without raising and would otherwise
        # propagate through the kernel's MAD outlier and weighted-mean math as
        # NaN, silently poisoning the consensus across all Sources. A zero or
        # negative price is also rejected — no real BTC market quotes 0 — but
        # zero quote-volume is allowed (the kernel handles it; see
        # core_zero_volume_spec.rb).
        unless price_bd.finite? && volume_24h_bd.finite? && vwap_24h_bd.finite?
          raise MalformedResponse, "kraken: non-finite numeric in payload (price=#{price_bd}, volume=#{volume_24h_bd}, vwap=#{vwap_24h_bd})"
        end
        unless price_bd.positive?
          raise MalformedResponse, "kraken: non-positive price #{price_bd.to_s('F')}"
        end

        Aggregator::Tick.new(
          exchange:         name,
          pair:             canonical_pair,
          price:            price_bd,
          quote_volume_24h: volume_24h_bd * vwap_24h_bd,
          source_ts:        parse_date_header(response),
          ingested_ts:      Time.now.utc
        )
      rescue KeyError => e
        raise MalformedResponse, "kraken: missing field #{e.key.inspect}"
      rescue ArgumentError, TypeError => e
        # BigDecimal("not-a-number") raises ArgumentError; BigDecimal(nil)
        # raises TypeError. Same discipline as Binance/Coinbase: do NOT
        # catch NoMethodError — that would swallow programmer typos as
        # "malformed payload."
        raise MalformedResponse, "kraken: malformed payload — #{e.message}"
      end

      # Kraken returns the [today, 24h] arrays as length-2 arrays of
      # decimal strings. We assert the shape explicitly so a future
      # API change (e.g. Kraken collapsing to a single value) raises a
      # clear MalformedResponse instead of an opaque NoMethodError.
      def pick_24h(arr, field:, index:)
        unless arr.is_a?(Array) && arr.length > index
          # Truncate the inspected upstream value — a multi-MB array of
          # garbage from a hostile/buggy upstream would otherwise be
          # echoed verbatim into the exception message and logs.
          raise MalformedResponse, "kraken: field #{field.inspect} is not a length-#{index + 1}+ array (#{arr.inspect[0, 256]})"
        end
        arr[index]
      end

      # Kraken's ticker payload has no body-level server timestamp. We
      # anchor `source_ts` to the HTTP `Date` response header — the same
      # approach Coinbase takes (see ADR 0003) and re-affirmed for Kraken
      # in ADR 0004. Helper deliberately copied rather than extracted to
      # Base: the per-adapter readability stance the README defends for
      # SYMBOL_MAP applies symmetrically here. Two adapters needing the
      # same 7 lines is below the rule-of-three threshold.
      def parse_date_header(response)
        raw = response.headers["Date"] || response.headers["date"]
        raise MalformedResponse, "kraken: missing Date response header" if raw.nil?

        Time.httpdate(raw).utc
      rescue ArgumentError => e
        # Truncate the upstream-controlled Date echo (same reasoning as
        # the API-error truncation above).
        raise MalformedResponse, "kraken: unparseable Date header #{raw.inspect[0, 256]} — #{e.message}"
      end
    end
  end
end
