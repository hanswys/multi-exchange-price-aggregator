require "rails_helper"

RSpec.describe Aggregator::Sources::Kraken do
  describe "#fetch", :vcr do
    it "translates canonical BTC-USD to Kraken's XXBTZUSD on the wire and back into a normalized Tick",
       vcr: { cassette_name: "kraken/ticker_xxbtzusd" } do
      tick = described_class.new.fetch("BTC-USD")

      expect(tick).to be_a(Aggregator::Tick)
      expect(tick.exchange).to eq("kraken")
      expect(tick.pair).to eq("BTC-USD")
      # c[0] = "67432.20000" — the last-trade price, NOT the 24h VWAP.
      expect(tick.price).to eq(BigDecimal("67432.20000"))
      # quote_volume_24h = v[1] × p[1] = 12000 × 67500 = 810_000_000.
      # If the adapter ever silently switches to v[1] × c[0] this assertion
      # changes by ~$813k and the test screams. See ADR 0004.
      expect(tick.quote_volume_24h)
        .to eq(BigDecimal("12000.00000000") * BigDecimal("67500.00000000"))
      # source_ts comes from the HTTP `Date` response header — Kraken's
      # ticker payload has no body-level timestamp. See ADR 0004.
      expect(tick.source_ts).to eq(Time.utc(2026, 5, 3, 16, 0, 0))
      expect(tick.ingested_ts).to be_within(30.seconds).of(Time.now.utc)

      # The wire-level assertion: the canonical pair was translated to
      # Kraken's X-prefix / Z-prefix native symbol before the request.
      expect(WebMock).to have_requested(:get, "https://api.kraken.com/0/public/Ticker")
        .with(query: { pair: "XXBTZUSD" })
    end
  end
end
