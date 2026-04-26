require "rails_helper"
require "json"

RSpec.describe Aggregator::Core, "replay against captured exchange fixtures" do
  let(:fixtures_dir) { Rails.root.join("spec/fixtures/exchanges") }
  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  def load_fixture(name)
    JSON.parse(File.read(fixtures_dir.join(name))).map do |payload|
      Aggregator::Tick.new(
        exchange:         payload.fetch("exchange"),
        pair:             payload.fetch("pair"),
        price:            BigDecimal(payload.fetch("price")),
        quote_volume_24h: BigDecimal(payload.fetch("quote_volume_24h")),
        source_ts:        Time.iso8601(payload.fetch("source_ts")),
        ingested_ts:      Time.iso8601(payload.fetch("ingested_ts"))
      )
    end
  end

  let(:ticks) { load_fixture("clean.json") + load_fixture("stale.json") + load_fixture("outlier.json") }

  subject(:result) { described_class.compute(ticks: ticks, now: now) }

  it "rejects the stale tick with reason: 'stale'" do
    rejection = result.sources_rejected.find { |r| r[:exchange] == "kraken" }
    expect(rejection).not_to be_nil
    expect(rejection[:reason]).to eq("stale")
  end

  it "rejects the outlier tick with reason: 'outlier'" do
    rejection = result.sources_rejected.find { |r| r[:exchange] == "okx" }
    expect(rejection).not_to be_nil
    expect(rejection[:reason]).to eq("outlier")
  end

  it "uses the two clean sources for the consensus" do
    used_exchanges = result.sources_used.map { |s| s[:exchange] }
    expect(used_exchanges).to contain_exactly("binance", "coinbase")
  end

  it "sets confidence to 'degraded_outlier'" do
    expect(result.confidence).to eq("degraded_outlier")
  end

  it "returns a vwap weighted by quote_volume_24h (binance 100, coinbase 50)" do
    expected = (BigDecimal("67430.50") * 100 + BigDecimal("67434.00") * 50) / 150
    expect(result.vwap).to be_within(BigDecimal("0.01")).of(expected)
  end

  it "emits a structured rejection list with exchange/reason/detail" do
    expect(result.sources_rejected.size).to eq(2)
    result.sources_rejected.each do |r|
      expect(r).to include(:exchange, :reason, :detail)
      expect(r[:detail]).to be_a(String)
      expect(r[:detail]).not_to be_empty
    end
  end
end
