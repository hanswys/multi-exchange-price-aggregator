require "rails_helper"

# CRITICAL silent-failure spec.
# Below MIN_SOURCES the kernel must NOT return a result — that would be lying
# about the price. It raises Aggregator::InsufficientSources, which the
# controller layer translates to HTTP 503.
RSpec.describe Aggregator::Core, "when fewer than MIN_SOURCES survive" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  let(:single_healthy_tick) do
    Aggregator::Tick.new(
      exchange:         "binance",
      pair:             "BTC-USD",
      price:            BigDecimal("67430.50"),
      quote_volume_24h: BigDecimal("100"),
      source_ts:        now - 1,
      ingested_ts:      now
    )
  end

  let(:stale_tick) do
    Aggregator::Tick.new(
      exchange:         "coinbase",
      pair:             "BTC-USD",
      price:            BigDecimal("67434.00"),
      quote_volume_24h: BigDecimal("50"),
      source_ts:        now - 30,
      ingested_ts:      now
    )
  end

  it "raises Aggregator::InsufficientSources" do
    expect {
      described_class.compute(ticks: [ single_healthy_tick, stale_tick ], now: now)
    }.to raise_error(Aggregator::InsufficientSources)
  end

  it "carries sources_used count, sources_required, and the rejection list on the error" do
    described_class.compute(ticks: [ single_healthy_tick, stale_tick ], now: now)
  rescue Aggregator::InsufficientSources => e
    expect(e.sources_used).to eq(1)
    expect(e.sources_required).to eq(Aggregator::Constants::MIN_SOURCES)
    expect(e.sources_rejected.map { |r| r[:exchange] }).to include("coinbase")
  end

  it "raises when given zero ticks" do
    expect {
      described_class.compute(ticks: [], now: now)
    }.to raise_error(Aggregator::InsufficientSources)
  end
end
