require "rails_helper"

RSpec.describe ExchangePollJob, type: :job do
  let(:porotick) do
    Aggregator::Tick.new(
      exchange:         "binance",
      pair:             "BTC-USD",
      price:            BigDecimal("67000"),
      quote_volume_24h: BigDecimal("1000"),
      source_ts:        1.second.ago,
      ingested_ts:      Time.now.utc
    )
  end

  let(:fake_adapter) { instance_double(Aggregator::Sources::Binance) }

  before { allow(Aggregator::Sources::Binance).to receive(:new).and_return(fake_adapter) }

  describe "#perform on a healthy fetch" do
    it "writes a Tick and self-reschedules the chain" do
      allow(fake_adapter).to receive(:fetch).and_return(porotick)

      expect { described_class.new.perform("binance") }
        .to change(Tick, :count).by(1)
        .and change(described_class.jobs, :size).by(1)

      scheduled = described_class.jobs.last
      expect(scheduled["args"]).to eq([ "binance" ])
      # `at` is the absolute Unix epoch the job is scheduled to run.
      expect(scheduled["at"] - Time.now.to_f)
        .to be_within(0.5).of(Aggregator::Constants::POLLING_INTERVAL)
    end
  end

  describe "#perform when the adapter raises Unreachable" do
    it "kills the chain — no Tick written, no reschedule" do
      allow(fake_adapter).to receive(:fetch)
        .and_raise(Aggregator::Sources::Unreachable, "binance unreachable")

      expect { described_class.new.perform("binance") }.not_to change(Tick, :count)
      expect(described_class.jobs).to be_empty
    end
  end

  describe "#perform when the adapter raises Unhealthy" do
    it "kills the chain — no Tick written, no reschedule" do
      allow(fake_adapter).to receive(:fetch)
        .and_raise(Aggregator::Sources::Unhealthy, "binance is unhealthy")

      expect { described_class.new.perform("binance") }.not_to change(Tick, :count)
      expect(described_class.jobs).to be_empty
    end
  end

  describe "#perform when the adapter raises MalformedResponse" do
    it "continues the chain — no Tick written, but reschedule fires" do
      allow(fake_adapter).to receive(:fetch)
        .and_raise(Aggregator::Sources::MalformedResponse, "binance: missing field 'lastPrice'")

      expect { described_class.new.perform("binance") }.not_to change(Tick, :count)
      expect(described_class.jobs.size).to eq(1)
      expect(described_class.jobs.last["args"]).to eq([ "binance" ])
    end
  end

  describe "#perform when an unanticipated StandardError raises" do
    it "propagates and does not reschedule (Sidekiq dead set is the audit trail)" do
      allow(fake_adapter).to receive(:fetch).and_raise(RuntimeError, "boom")

      expect { described_class.new.perform("binance") }.to raise_error(RuntimeError, "boom")
      expect(described_class.jobs).to be_empty
    end
  end
end
