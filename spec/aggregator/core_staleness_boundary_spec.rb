require "rails_helper"

# CRITICAL silent-failure spec.
# Off-by-one at the SLO boundary is the kind of bug only caught in production.
# The chosen rule: a tick whose age >= STALENESS_SLO is rejected. A tick at
# exactly 10.000s is on the drop side.
RSpec.describe Aggregator::Core, "at the staleness SLO boundary" do
  let(:now)  { Time.utc(2026, 4, 26, 12, 0, 0) }
  let(:slo)  { Aggregator::Constants::STALENESS_SLO.to_f }

  def make_tick(exchange:, age:)
    Aggregator::Tick.new(
      exchange:         exchange,
      pair:             "BTC-USD",
      price:            BigDecimal("67432.00"),
      quote_volume_24h: BigDecimal("100"),
      source_ts:        now - age,
      ingested_ts:      now
    )
  end

  it "rejects a tick at exactly 10.000s old" do
    boundary    = make_tick(exchange: "kraken",   age: slo)
    healthy_a   = make_tick(exchange: "binance",  age: 1)
    healthy_b   = make_tick(exchange: "coinbase", age: 1)

    result = described_class.compute(ticks: [ boundary, healthy_a, healthy_b ], now: now)

    rejection = result.sources_rejected.find { |r| r[:exchange] == "kraken" }
    expect(rejection).not_to be_nil
    expect(rejection[:reason]).to eq("stale")
    expect(result.sources_used.map { |s| s[:exchange] }).to contain_exactly("binance", "coinbase")
  end

  it "keeps a tick just inside the boundary (9.999s old)" do
    just_fresh  = make_tick(exchange: "kraken",   age: slo - 0.001)
    healthy_a   = make_tick(exchange: "binance",  age: 1)
    healthy_b   = make_tick(exchange: "coinbase", age: 1)

    result = described_class.compute(ticks: [ just_fresh, healthy_a, healthy_b ], now: now)

    expect(result.sources_used.map { |s| s[:exchange] }).to contain_exactly("binance", "coinbase", "kraken")
    expect(result.sources_rejected).to be_empty
  end
end
