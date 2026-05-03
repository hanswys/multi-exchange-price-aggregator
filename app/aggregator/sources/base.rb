require "faraday"

module Aggregator
  module Sources
    # Shared HTTP + retry + circuit-breaker scaffolding for exchange
    # adapters. Subclasses override:
    #   - #name           : lowercase Source name (used as the Tick's
    #                       `exchange:` field and the Redis key fragment)
    #   - #base_url       : scheme + host
    #   - #request(canonical_pair) : returns a Faraday::Response
    #   - #parse_payload(body, canonical_pair) : returns Aggregator::Tick
    #
    # The contract of #fetch is documented in
    # docs/adr/0001-source-adapter-fetch-contract.md.
    class Base
      def initialize(http: nil, redis_pool: Aggregator::REDIS_POOL)
        @http = http || build_connection
        @redis_pool = redis_pool
      end

      def name
        raise NotImplementedError
      end

      # Returns Aggregator::Tick or raises Aggregator::Sources::Error.
      #
      # Failure ladder for one call:
      #   - circuit already open                          → Unhealthy
      #   - 200 with parseable body                        → Tick
      #   - 200 with malformed body                        → MalformedResponse
      #   - 429: sleep Retry-After, retry (counts toward budget)
      #   - 5xx or network error: sleep RETRY_BACKOFF_MS[attempt], retry
      #   - retry budget exhausted (4 attempts total)      → mark Unhealthy, raise Unreachable
      def fetch(canonical_pair)
        raise Unhealthy, "#{name} is unhealthy" if unhealthy?

        last_error = nil
        # RETRY_BACKOFF_MS holds the sleep durations BETWEEN attempts, so the
        # number of attempts is one more than the number of sleeps.
        max_attempts = Constants::RETRY_BACKOFF_MS.size + 1

        max_attempts.times do |attempt|
          retry_after_override = nil

          begin
            response = request(canonical_pair)

            if response.status == 429
              last_error = "rate limited (HTTP 429)"
              retry_after_override = retry_after_seconds(response)
            elsif response.status >= 500
              last_error = "HTTP #{response.status}"
            else
              return parse_payload(response.body, canonical_pair)
            end
          rescue Faraday::Error => e
            last_error = e.message
          end

          break if attempt >= Constants::RETRY_BACKOFF_MS.size
          delay = retry_after_override || (Constants::RETRY_BACKOFF_MS[attempt] / 1000.0)
          sleep(delay)
        end

        mark_unhealthy!
        raise Unreachable, "#{name} unreachable after #{max_attempts} attempts: #{last_error}"
      end

      def unhealthy?
        @redis_pool.with { |r| r.exists?(unhealthy_key) }
      end

      private

      def mark_unhealthy!
        @redis_pool.with do |r|
          r.set(unhealthy_key, "1", ex: Constants::UNHEALTHY_TTL.to_i)
        end
      end

      def unhealthy_key
        "aggregator:source:#{name}:unhealthy"
      end

      # Returns the integer seconds value of the Retry-After header, capped
      # at RETRY_AFTER_MAX_S. Returns nil if the header is absent, malformed,
      # in HTTP-date format (which we intentionally don't parse), or larger
      # than the cap — in any of those cases we fall back to RETRY_BACKOFF_MS,
      # which is bounded.
      def retry_after_seconds(response)
        raw = response.headers["Retry-After"] || response.headers["retry-after"]
        return nil if raw.nil?
        seconds = Integer(raw)
        return nil if seconds > Constants::RETRY_AFTER_MAX_S || seconds.negative?
        seconds
      rescue ArgumentError, TypeError
        nil
      end

      def build_connection
        Faraday.new(url: base_url) do |f|
          f.options.open_timeout = Constants::HTTP_OPEN_TIMEOUT
          f.options.timeout      = Constants::HTTP_READ_TIMEOUT
          f.headers["Accept"]    = "application/json"
          f.headers["User-Agent"] = "aggregator-#{name}-adapter/1.0"
          f.adapter Faraday.default_adapter
        end
      end

      def base_url
        raise NotImplementedError
      end

      def request(_canonical_pair)
        raise NotImplementedError
      end

      def parse_payload(_body, _canonical_pair)
        raise NotImplementedError
      end
    end
  end
end
