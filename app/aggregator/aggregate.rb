module Aggregator
  # Value object returned by Aggregator::Core.compute.
  #
  # Decimal fields (vwap, per-source price/weight) are kept as BigDecimal
  # internally. #to_h / #as_json render them as decimal strings so the JSON
  # response never sends currency through IEEE-754.
  class Aggregate
    CONFIDENCE_LEVELS = %w[ok degraded_outlier degraded_unreachable].freeze

    attr_reader :pair, :vwap, :confidence, :sources_used, :sources_rejected,
                :as_of, :window_seconds

    def initialize(pair:, vwap:, confidence:, sources_used:, sources_rejected:,
                   as_of:, window_seconds:)
      raise ArgumentError, "invalid confidence: #{confidence.inspect}" unless CONFIDENCE_LEVELS.include?(confidence)

      @pair             = pair
      @vwap             = vwap
      @confidence       = confidence
      @sources_used     = sources_used
      @sources_rejected = sources_rejected
      @as_of            = as_of
      @window_seconds   = window_seconds
    end

    def to_h
      {
        pair: pair,
        vwap: format_decimal(vwap),
        confidence: confidence,
        as_of: as_of.utc.iso8601(3),
        window_seconds: window_seconds,
        sources_used: sources_used.map { |s| serialize_used(s) },
        sources_rejected: sources_rejected.map { |s| serialize_rejected(s) }
      }
    end
    alias_method :as_json, :to_h

    private

    def serialize_used(source)
      {
        exchange:  source[:exchange],
        price:     format_decimal(source[:price]),
        weight:    format_decimal(source[:weight], scale: 4),
        source_ts: source[:source_ts].utc.iso8601(3)
      }
    end

    def serialize_rejected(source)
      {
        exchange: source[:exchange],
        reason:   source[:reason],
        detail:   source[:detail]
      }
    end

    def format_decimal(value, scale: 8)
      BigDecimal(value.to_s).round(scale).to_s("F")
    end
  end
end
