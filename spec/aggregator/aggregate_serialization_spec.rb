require "rails_helper"

# CRITICAL silent-failure spec.
# Currency through IEEE-754 is a real bug. The kernel works in BigDecimal
# internally; the serialized hash (consumed by the controller) must render
# vwap, price, and weight as decimal STRINGS, not JSON numbers.
RSpec.describe Aggregator::Aggregate, "serialization shape" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  let(:ticks) do
    [
      Aggregator::Tick.new(
        exchange:         "binance",
        pair:             "BTC-USD",
        price:            BigDecimal("67430.50"),
        quote_volume_24h: BigDecimal("100"),
        source_ts:        now - 1,
        ingested_ts:      now
      ),
      Aggregator::Tick.new(
        exchange:         "coinbase",
        pair:             "BTC-USD",
        price:            BigDecimal("67434.00"),
        quote_volume_24h: BigDecimal("50"),
        source_ts:        now - 1,
        ingested_ts:      now
      ),
      Aggregator::Tick.new(
        exchange:         "kraken",
        pair:             "BTC-USD",
        price:            BigDecimal("67432.00"),
        quote_volume_24h: BigDecimal("75"),
        source_ts:        now - 1,
        ingested_ts:      now
      )
    ]
  end

  let(:aggregate) { Aggregator::Core.compute(ticks: ticks, now: now) }
  let(:hash) { aggregate.to_h }

  it "renders vwap as a String" do
    expect(hash[:vwap]).to be_a(String)
  end

  it "renders each source's price as a String" do
    expect(hash[:sources_used]).to all(satisfy { |s| s[:price].is_a?(String) })
  end

  it "renders each source's weight as a String" do
    expect(hash[:sources_used]).to all(satisfy { |s| s[:weight].is_a?(String) })
  end

  it "never serializes a Float for any decimal field" do
    decimal_values = [
      hash[:vwap],
      *hash[:sources_used].map { |s| s[:price] },
      *hash[:sources_used].map { |s| s[:weight] }
    ]
    expect(decimal_values).to all(be_a(String))
    expect(decimal_values.any? { |v| v.is_a?(Float) }).to be(false)
  end

  it "round-trips through JSON without converting decimals to floats" do
    parsed = JSON.parse(hash.to_json)
    expect(parsed["vwap"]).to be_a(String)
    parsed["sources_used"].each do |source|
      expect(source["price"]).to be_a(String)
      expect(source["weight"]).to be_a(String)
    end
  end

  it "renders as_of as an ISO8601 string with millisecond precision" do
    expect(hash[:as_of]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
  end

  it "renders window_seconds as an Integer" do
    expect(hash[:window_seconds]).to eq(10)
  end
end
