require "rails_helper"

# Per the design's "MAD baseline" definition:
# "Median of latest one tick per source within the aggregation window."
# Two ticks from the same exchange must NOT both contribute to the median or
# the weighting — only the freshest is used.
RSpec.describe Aggregator::Core, "dedup: latest tick per exchange" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  def make_tick(exchange:, age:, price:, vol: "100")
    Aggregator::Tick.new(
      exchange:         exchange,
      pair:             "BTC-USD",
      price:            BigDecimal(price),
      quote_volume_24h: BigDecimal(vol),
      source_ts:        now - age,
      ingested_ts:      now
    )
  end

  it "uses only the freshest tick per exchange when duplicates are present" do
    older    = make_tick(exchange: "binance",  age: 5, price: "67000.00")
    fresher  = make_tick(exchange: "binance",  age: 1, price: "67430.50")
    coinbase = make_tick(exchange: "coinbase", age: 1, price: "67434.00", vol: "50")

    result = described_class.compute(ticks: [ older, fresher, coinbase ], now: now)

    binance = result.sources_used.find { |s| s[:exchange] == "binance" }
    expect(binance[:price]).to eq(BigDecimal("67430.50"))
    expect(result.sources_used.size).to eq(2)
  end
end
