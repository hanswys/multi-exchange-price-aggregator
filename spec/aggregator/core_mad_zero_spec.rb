require "rails_helper"

# CRITICAL silent-failure spec.
# When all sources report the identical price, MAD = 0. Naive code computes
# (price - median) / MAD and explodes; the kernel must skip outlier filtering
# and use every source.
RSpec.describe Aggregator::Core, "when MAD = 0" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  let(:ticks) do
    [ "binance", "coinbase", "kraken" ].map do |ex|
      Aggregator::Tick.new(
        exchange:         ex,
        pair:             "BTC-USD",
        price:            BigDecimal("67432.00"),
        quote_volume_24h: BigDecimal("100"),
        source_ts:        now - 1,
        ingested_ts:      now
      )
    end
  end

  subject(:result) { described_class.compute(ticks: ticks, now: now) }

  it "does not raise (no division by zero)" do
    expect { result }.not_to raise_error
  end

  it "treats no source as an outlier" do
    expect(result.sources_rejected).to be_empty
  end

  it "uses all three sources" do
    expect(result.sources_used.size).to eq(3)
  end

  it "reports confidence: 'ok'" do
    expect(result.confidence).to eq("ok")
  end

  it "returns the agreed-upon price as the vwap" do
    expect(result.vwap).to eq(BigDecimal("67432.00"))
  end
end
