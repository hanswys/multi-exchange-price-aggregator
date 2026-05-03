require "rails_helper"

RSpec.describe BroadcastTickJob, type: :job do
  describe "#perform when the aggregation window is healthy" do
    before do
      Aggregator::Sources::REGISTRY.each_with_index do |ex, i|
        Tick.create!(
          exchange:         ex,
          pair:             "BTC-USD",
          price:            BigDecimal("67000") + i,
          quote_volume_24h: BigDecimal("1000"),
          source_ts:        Time.now.utc - 1,
          ingested_ts:      Time.now.utc - 1
        )
      end
    end

    it "broadcasts an update of the consensus partial to :price_BTC_USD targeting consensus_hero" do
      expect(Turbo::StreamsChannel).to receive(:broadcast_update_to).with(
        :price_BTC_USD,
        target:  "consensus_hero",
        partial: "dashboard/consensus",
        locals:  hash_including(agg: an_instance_of(Aggregator::Aggregate))
      )

      described_class.new.perform
    end

    it "self-reschedules at BROADCAST_INTERVAL after success" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)

      expect { described_class.new.perform }.to change(described_class.jobs, :size).by(1)

      scheduled = described_class.jobs.last
      expect(scheduled["at"] - Time.now.to_f)
        .to be_within(0.5).of(Aggregator::Constants::BROADCAST_INTERVAL)
    end
  end

  describe "#perform when the kernel raises InsufficientSources" do
    before do
      Tick.create!(
        exchange:         "binance",
        pair:             "BTC-USD",
        price:            BigDecimal("67000"),
        quote_volume_24h: BigDecimal("1000"),
        source_ts:        Time.now.utc - 1,
        ingested_ts:      Time.now.utc - 1
      )
    end

    it "broadcasts the error partial to consensus_hero (does not skip)" do
      expect(Turbo::StreamsChannel).to receive(:broadcast_update_to).with(
        :price_BTC_USD,
        target:  "consensus_hero",
        partial: "dashboard/state_error",
        locals:  hash_including(:last_good_price, :last_good_age)
      )

      described_class.new.perform
    end

    it "self-reschedules at BROADCAST_INTERVAL after the rescue" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_update_to)

      expect { described_class.new.perform }.to change(described_class.jobs, :size).by(1)

      scheduled = described_class.jobs.last
      expect(scheduled["at"] - Time.now.to_f)
        .to be_within(0.5).of(Aggregator::Constants::BROADCAST_INTERVAL)
    end
  end

  describe "in-flight sentinel" do
    before { allow(Turbo::StreamsChannel).to receive(:broadcast_update_to) }

    it ".in_flight? is false before any chain has run" do
      expect(described_class.in_flight?).to eq(false)
    end

    it "#perform sets the sentinel so subsequent .in_flight? returns true" do
      described_class.new.perform
      expect(described_class.in_flight?).to eq(true)
    end

    it ".kick enqueues a chain only when not already in flight" do
      expect { described_class.kick }.to change(described_class.jobs, :size).by(1)
      described_class.new.perform # marks in flight
      expect { described_class.kick }.not_to change(described_class.jobs, :size)
    end
  end
end
