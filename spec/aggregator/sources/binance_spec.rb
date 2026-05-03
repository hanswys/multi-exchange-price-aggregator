require "rails_helper"

RSpec.describe Aggregator::Sources::Binance do
  describe "#fetch", :vcr do
    it "returns a normalized Tick from /api/v3/ticker/24hr",
       vcr: { cassette_name: "binance/ticker_24hr_btcusdt" } do
      tick = described_class.new.fetch("BTC-USD")

      expect(tick).to be_a(Aggregator::Tick)
      expect(tick.exchange).to eq("binance")
      expect(tick.pair).to eq("BTC-USD")
      expect(tick.price).to eq(BigDecimal("67430.50"))
      expect(tick.quote_volume_24h).to eq(BigDecimal("1350000000.00000000"))
      expect(tick.source_ts).to eq(Time.at(1_777_824_000).utc)
      expect(tick.ingested_ts).to be_within(5.seconds).of(Time.now.utc)
    end
  end
end
