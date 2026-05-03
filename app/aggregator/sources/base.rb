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
      OPEN_TIMEOUT = 2
      READ_TIMEOUT = 5

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

      def retry_after_seconds(response)
        Integer(response.headers["Retry-After"] || response.headers["retry-after"])
      end

      def build_connection
        Faraday.new(url: base_url) do |f|
          f.options.open_timeout = OPEN_TIMEOUT
          f.options.timeout      = READ_TIMEOUT
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
