require "rails_helper"

# CRITICAL silent-failure spec.
# A source reporting quote_volume_24h = 0 (e.g. exchange in maintenance) would
# cause division by zero in the volume-weighted sum. The kernel drops the
# source and labels it 'unreachable'.
RSpec.describe Aggregator::Core, "when a source reports zero quote volume" do
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  let(:zero_volume_tick) do
    Aggregator::Tick.new(
      exchange:         "kraken",
      pair:             "BTC-USD",
      price:            BigDecimal("67432.00"),
      quote_volume_24h: BigDecimal("0"),
      source_ts:        now - 1,
      ingested_ts:      now
    )
  end

  let(:healthy_ticks) do
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
      )
    ]
  end

  subject(:result) { described_class.compute(ticks: healthy_ticks + [ zero_volume_tick ], now: now) }

  it "does not raise (no division by zero in the weight calculation)" do
    expect { result }.not_to raise_error
  end

  it "rejects the zero-volume source with reason: 'unreachable'" do
    rejection = result.sources_rejected.find { |r| r[:exchange] == "kraken" }
    expect(rejection).not_to be_nil
    expect(rejection[:reason]).to eq("unreachable")
  end

  it "computes the vwap from the remaining healthy sources only" do
    expected = (BigDecimal("67430.50") * 100 + BigDecimal("67434.00") * 50) / 150
    expect(result.vwap).to be_within(BigDecimal("0.01")).of(expected)
  end
end
