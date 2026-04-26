require "rails_helper"

# Median with an even number of values must average the two middle elements.
# Off-by-one here would silently shift the consensus by ~half a price tick on
# any 2/4-source configuration.
RSpec.describe Aggregator::Core, "median with an even number of sources" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  def make_tick(exchange:, price:)
    Aggregator::Tick.new(
      exchange:         exchange,
      pair:             "BTC-USD",
      price:            BigDecimal(price),
      quote_volume_24h: BigDecimal("100"),
      source_ts:        now - 1,
      ingested_ts:      now
    )
  end

  it "averages the two middle prices when given 4 sources" do
    # prices sorted: 100.00, 102.00, 104.00, 106.00
    # median = (102 + 104) / 2 = 103
    # all deviations: [3, 1, 1, 3] → sorted [1, 1, 3, 3] → median (MAD) = 2
    # threshold = 5 × 2 = 10 → no outliers
    result = described_class.compute(
      ticks: [
        make_tick(exchange: "binance",  price: "100.00"),
        make_tick(exchange: "coinbase", price: "102.00"),
        make_tick(exchange: "kraken",   price: "104.00"),
        make_tick(exchange: "okx",      price: "106.00")
      ],
      now: now
    )

    expect(result.sources_used.size).to eq(4)
    expect(result.sources_rejected).to be_empty
    expect(result.vwap).to eq(BigDecimal("103.00"))
  end
end
