require "rails_helper"

RSpec.describe Tick, type: :model do
  include ActiveSupport::Testing::TimeHelpers


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
        record = described_class.new(attrs.except(field))
        expect(record).not_to be_valid
        expect(record.errors[field]).to include("can't be blank")
      end
    end

    it "rejects DB-level null inserts" do
      expect {
        described_class.new(attrs.except(:price)).save(validate: false)
      }.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe "#to_value" do
    it "returns an Aggregator::Tick with matching attributes" do
      record = described_class.create!(attrs)
      value  = record.to_value

      expect(value).to be_a(Aggregator::Tick)
      expect(value.exchange).to         eq(attrs[:exchange])
      expect(value.pair).to             eq(attrs[:pair])
      expect(value.price).to            eq(attrs[:price])
      expect(value.quote_volume_24h).to eq(attrs[:quote_volume_24h])
      expect(value.source_ts).to        eq(attrs[:source_ts])
      expect(value.ingested_ts).to      eq(attrs[:ingested_ts])
    end

    it "round-trips through Aggregator::Tick equality" do
      record = described_class.create!(attrs)
      expect(record.to_value).to eq(Aggregator::Tick.new(attrs))
    end
  end

  describe ".recent_values" do
    let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

    before do
      described_class.create!(attrs.merge(ingested_ts: now - 1.second))   # in window
      described_class.create!(attrs.merge(ingested_ts: now - 5.seconds))  # in window
      described_class.create!(attrs.merge(ingested_ts: now - 30.seconds)) # outside default window
    end

    around { |ex| travel_to(now) { ex.run } }

    it "returns POROs, not ActiveRecord records" do
      values = described_class.recent_values
      expect(values).to all(be_a(Aggregator::Tick))
    end

    it "filters to ticks within the default AGGREGATION_WINDOW" do
      expect(described_class.recent_values.size).to eq(2)
    end

    it "honors a custom window argument" do
      expect(described_class.recent_values(window: 60.seconds).size).to eq(3)
      expect(described_class.recent_values(window: 2.seconds).size).to  eq(1)
    end

    it "orders by ingested_ts descending" do
      values = described_class.recent_values(window: 60.seconds)
      expect(values.map(&:ingested_ts)).to eq(values.map(&:ingested_ts).sort.reverse)
    end
  end

  describe "implicit_order_column" do
    it "uses ingested_ts as the default order so .first / .last work without a PK" do
      oldest_ts = Time.utc(2026, 4, 26, 11, 59, 30)
      newest_ts = Time.utc(2026, 4, 26, 11, 59, 59)

      described_class.create!(attrs.merge(ingested_ts: oldest_ts))
      described_class.create!(attrs.merge(ingested_ts: newest_ts))

      expect(described_class.first.ingested_ts).to eq(oldest_ts)
      expect(described_class.last.ingested_ts).to  eq(newest_ts)
    end
  end
end
