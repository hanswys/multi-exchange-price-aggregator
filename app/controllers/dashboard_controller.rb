class DashboardController < ApplicationController
  PAIR = "BTC-USD".freeze

  STATES = %i[loading empty partial error disconnect ok].freeze

  def show
    @pair = PAIR

    if (override = override_state)
      apply_override_fixture(override)
    else
      load_live_data
      @state = inferred_state
    end
  end

  private

  def load_live_data
    @ticks           = Tick.recent_values
    @missing_sources = (Aggregator::Sources::REGISTRY - @ticks.map(&:exchange).uniq)
    @aggregate       = compute_aggregate(@ticks)
    @last_good_price, @last_good_age = lookup_last_good
  end

  # Computes the Aggregate for live render. Returns nil on
  # InsufficientSources — the view branches on `@state`, not nil-ness.
  def compute_aggregate(ticks)
    return nil if ticks.empty?

    Aggregator::Core.compute(ticks: ticks)
  rescue Aggregator::InsufficientSources
    nil
  end

  # Last tick within a wider 60s window. Renders the "last good was X, Ys
  # ago" subtext on the 503 fallback. Snapshot at request time.
  def lookup_last_good
    last = Tick.recent_values(window: 60.seconds).first
    return [ nil, nil ] unless last

    [ last.price, (Time.now.utc - last.source_ts).round(1) ]
  end

  def inferred_state
    return :empty if @ticks.empty?
    return :error if @aggregate.nil?

    case @aggregate.confidence
    when "ok"                                       then :ok
    when "degraded_outlier", "degraded_unreachable" then :partial
    end
  end

  # Dev/test only — production traffic ignores ?state= so a crawler can't
  # force the dashboard into a fake state.
  def override_state
    return nil unless Rails.env.local?

    raw = params[:state]&.to_sym
    STATES.include?(raw) ? raw : nil
  end

  # When ?state= is used, render the demanded state with stub data so the
  # copy stays internally consistent (no "Insufficient sources — 3 of 3
  # healthy" weirdness). Live ticks are ignored on the override path.
  def apply_override_fixture(state)
    @state           = state
    @ticks           = []
    @missing_sources = Aggregator::Sources::REGISTRY.dup
    @aggregate       = nil
    @last_good_price = nil
    @last_good_age   = nil

    case state
    when :ok       then stub_aggregate(:ok)
    when :partial  then stub_aggregate(:partial)
    when :error    then stub_last_good
    when :disconnect
      stub_aggregate(:ok)
      stub_last_good
    end
  end

  def stub_aggregate(kind)
    used = case kind
    when :ok      then registry_used(BigDecimal("67432.18"))
    when :partial then registry_used(BigDecimal("67432.18")).first(2)
    end

    @ticks = used.map do |s|
      Aggregator::Tick.new(
        exchange:         s[:exchange],
        pair:             PAIR,
        price:            s[:price],
        quote_volume_24h: BigDecimal("1000"),
        source_ts:        Time.now.utc - 1,
        ingested_ts:      Time.now.utc - 1
      )
    end
    @missing_sources = Aggregator::Sources::REGISTRY - @ticks.map(&:exchange)
    @aggregate = Aggregator::Aggregate.new(
      pair:             PAIR,
      vwap:             BigDecimal("67432.18"),
      confidence:       kind == :ok ? "ok" : "degraded_unreachable",
      sources_used:     used,
      sources_rejected: [],
      as_of:            Time.now.utc,
      window_seconds:   Aggregator::Constants::AGGREGATION_WINDOW.to_i
    )
  end

  def stub_last_good
    @last_good_price = BigDecimal("67432.18")
    @last_good_age   = 8.0
  end

  def registry_used(base_price)
    Aggregator::Sources::REGISTRY.each_with_index.map do |name, i|
      {
        exchange:  name,
        price:     base_price + BigDecimal((i - 1).to_s),
        weight:    BigDecimal("0.333"),
        source_ts: Time.now.utc - 1
      }
    end
  end
end
