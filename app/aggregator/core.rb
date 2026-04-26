# Aggregator::Core.compute
# ─────────────────────────
# Input: array of Aggregator::Tick (from Tick.recent_values(window: 10s))
#
#   ticks ──→ filter_stale ──→ filter_outliers ──→ weight_and_sum
#               (drop ticks      (drop ticks         (quote_volume_24h
#                older than       beyond k×MAD        weighted; sum to
#                10s SLO)         from median)        Aggregate)
#
# Output: Aggregator::Aggregate { vwap, confidence, sources_used,
#                                 sources_rejected, as_of }
#
# Confidence ladder:
#   3 sources used       → "ok"
#   2 sources, 1 outlier → "degraded_outlier"
#   2 sources, 1 unreach → "degraded_unreachable"
#   <2 sources           → raise InsufficientSources (controller → 503)

module Aggregator
  module Core
    module_function

    def compute(ticks:, now: Time.now.utc)
      raise ArgumentError, "ticks must be an Array" unless ticks.is_a?(Array)

      pair = ticks.map(&:pair).uniq
      raise ArgumentError, "ticks must share a single pair, got: #{pair.inspect}" if pair.size > 1

      pair = pair.first
      latest = latest_per_exchange(ticks)
      window_seconds = Constants::AGGREGATION_WINDOW.to_i

      rejections = []

      fresh, stale = partition_stale(latest, now: now)
      stale.each { |t, age| rejections << stale_rejection(t, age) }

      with_volume, zero_volume = fresh.partition { |t| t.quote_volume_24h.to_d.positive? }
      zero_volume.each { |t| rejections << zero_volume_rejection(t) }

      kept, outliers = partition_outliers(with_volume)
      outliers.each { |t, median, mad| rejections << outlier_rejection(t, median, mad) }

      if kept.size < Constants::MIN_SOURCES
        raise InsufficientSources.new(
          sources_used:     kept.size,
          sources_required: Constants::MIN_SOURCES,
          sources_rejected: rejections
        )
      end

      vwap, used_with_weights = weight_and_sum(kept)

      Aggregate.new(
        pair:             pair,
        vwap:             vwap,
        confidence:       confidence_for(used_with_weights, rejections),
        sources_used:     used_with_weights,
        sources_rejected: rejections,
        as_of:            now,
        window_seconds:   window_seconds
      )
    end

    def latest_per_exchange(ticks)
      ticks.group_by(&:exchange).map { |_, group| group.max_by(&:source_ts) }
    end

    def partition_stale(ticks, now:)
      slo = Constants::STALENESS_SLO.to_f
      fresh = []
      stale = []
      ticks.each do |t|
        age = now - t.source_ts
        if age >= slo
          stale << [ t, age ]
        else
          fresh << t
        end
      end
      [ fresh, stale ]
    end

    def partition_outliers(ticks)
      return [ ticks, [] ] if ticks.size < 2

      prices = ticks.map { |t| t.price.to_d }
      median = median_of(prices)
      deviations = prices.map { |p| (p - median).abs }
      mad = median_of(deviations)

      return [ ticks, [] ] if mad.zero?

      threshold = mad * BigDecimal(Constants::MAD_K.to_s)
      kept = []
      outliers = []
      ticks.each do |t|
        if (t.price.to_d - median).abs > threshold
          outliers << [ t, median, mad ]
        else
          kept << t
        end
      end
      [ kept, outliers ]
    end

    def median_of(values)
      sorted = values.sort
      n = sorted.size
      mid = n / 2
      n.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    end

    def weight_and_sum(ticks)
      total_volume = ticks.sum { |t| t.quote_volume_24h.to_d }
      weighted_sum = ticks.sum(BigDecimal("0")) { |t| t.price.to_d * t.quote_volume_24h.to_d }
      vwap = weighted_sum / total_volume
      sources = ticks.map do |t|
        {
          exchange:  t.exchange,
          price:     t.price.to_d,
          weight:    t.quote_volume_24h.to_d / total_volume,
          source_ts: t.source_ts
        }
      end
      [ vwap, sources ]
    end

    def confidence_for(used, rejections)
      if rejections.empty? && used.size >= 3
        "ok"
      elsif rejections.any? { |r| r[:reason] == "outlier" }
        "degraded_outlier"
      else
        "degraded_unreachable"
      end
    end

    def stale_rejection(tick, age)
      {
        exchange: tick.exchange,
        reason:   "stale",
        detail:   "source_ts age #{format('%.1f', age)}s >= SLO #{Constants::STALENESS_SLO.to_i}s"
      }
    end

    def zero_volume_rejection(tick)
      {
        exchange: tick.exchange,
        reason:   "unreachable",
        detail:   "quote_volume_24h is 0; source treated as unreachable"
      }
    end

    def outlier_rejection(tick, median, mad)
      k = (tick.price.to_d - median).abs / mad
      {
        exchange: tick.exchange,
        reason:   "outlier",
        detail:   "price #{tick.price.to_d.to_s('F')} vs median #{median.to_s('F')}, " \
                  "MAD #{mad.to_s('F')}, k=#{k.round(2).to_s('F')}"
      }
    end
  end
end
