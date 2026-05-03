require "rails_helper"

RSpec.describe Aggregator::Sources::Coinbase do
  describe "#fetch", :vcr do
    it "returns a normalized Tick from /api/v3/brokerage/market/products/BTC-USD",
       vcr: { cassette_name: "coinbase/market_product_btcusd" } do
      tick = described_class.new.fetch("BTC-USD")

      expect(tick).to be_a(Aggregator::Tick)
      expect(tick.exchange).to eq("coinbase")
      expect(tick.pair).to eq("BTC-USD")
      expect(tick.price).to eq(BigDecimal("67432.18"))
      # quote_volume_24h is computed: BigDecimal(volume_24h) * BigDecimal(price)
      # = BigDecimal("12000.00000000") * BigDecimal("67432.18")
      # = BigDecimal("809186160.00")
      expect(tick.quote_volume_24h).to eq(BigDecimal("12000.00000000") * BigDecimal("67432.18"))
      # source_ts comes from the HTTP `Date` response header — see ADR 0003.
      expect(tick.source_ts).to eq(Time.utc(2026, 5, 3, 16, 0, 0))
      expect(tick.ingested_ts).to be_within(30.seconds).of(Time.now.utc)

      expect(WebMock).to have_requested(:get, "https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD")
    end
  end
end
