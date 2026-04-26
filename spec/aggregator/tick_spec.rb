require "rails_helper"

RSpec.describe Aggregator::Tick do
  let(:attrs) do
    {
      exchange:         "binance",
      pair:             "BTC-USD",
      price:            BigDecimal("67432.18000000"),
      quote_volume_24h: BigDecimal("1234567890.12345678"),
      source_ts:        Time.utc(2026, 4, 26, 12, 0, 0),
      ingested_ts:      Time.utc(2026, 4, 26, 12, 0, 1)
    }
  end

  describe "validations" do
    it "is valid with all attributes" do
      expect(described_class.new(attrs)).to be_valid
    end

    %i[exchange pair price quote_volume_24h source_ts ingested_ts].each do |field|
      it "is invalid without #{field}" do
        tick = described_class.new(attrs.except(field))
        expect(tick).not_to be_valid
        expect(tick.errors[field]).to include("can't be blank")
      end
    end
  end

  describe "type coercion" do
    it "coerces price to BigDecimal" do
      tick = described_class.new(attrs.merge(price: "100.50"))
      expect(tick.price).to eq(BigDecimal("100.50"))
      expect(tick.price).to be_a(BigDecimal)
    end

    it "coerces timestamps to Time-like values" do
      tick = described_class.new(attrs.merge(source_ts: "2026-04-26T12:00:00Z"))
      expect(tick.source_ts).to be_a(Time)
    end
  end

  describe "equality" do
    it "is equal to another Tick with the same attributes" do
      expect(described_class.new(attrs)).to eq(described_class.new(attrs))
    end

    it "is not equal when an attribute differs" do
      a = described_class.new(attrs)
      b = described_class.new(attrs.merge(price: BigDecimal("99999.99")))
      expect(a).not_to eq(b)
    end
  end
end
