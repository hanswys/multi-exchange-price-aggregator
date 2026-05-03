require "rails_helper"

RSpec.describe PollerSupervisorJob, type: :job do
  describe "#perform" do
    it "self-reschedules at the start of perform (before doing any work)" do
      expect { described_class.new.perform }
        .to change(described_class.jobs, :size).by(1)

      scheduled = described_class.jobs.last
      expect(scheduled["at"] - Time.now.to_f).to be_within(2.0).of(60.0)
    end

    context "when no Source has any Tick yet (cold start)" do
      it "enqueues an ExchangePollJob for every Source in REGISTRY" do
        expect { described_class.new.perform }
          .to change(ExchangePollJob.jobs, :size).by(Aggregator::Sources::REGISTRY.size)

        enqueued_args = ExchangePollJob.jobs.map { |j| j["args"].first }
        expect(enqueued_args).to match_array(Aggregator::Sources::REGISTRY)
      end
    end

    context "when a Source has a recent Tick (chain is alive)" do
      it "does not enqueue a poll job for that Source" do
        Tick.create!(
          exchange:         "binance",
          pair:             "BTC-USD",
          price:            BigDecimal("67000"),
          quote_volume_24h: BigDecimal("1000"),
          source_ts:        1.second.ago,
          ingested_ts:      1.second.ago
        )

        expect { described_class.new.perform }.not_to change(ExchangePollJob.jobs, :size)
      end
    end

    context "when a Source's latest Tick is stale and the Source is Unhealthy" do
      it "does not enqueue a poll job (Unhealthy short-circuit)" do
        Tick.create!(
          exchange:         "binance",
          pair:             "BTC-USD",
          price:            BigDecimal("67000"),
          quote_volume_24h: BigDecimal("1000"),
          source_ts:        1.minute.ago,
          ingested_ts:      1.minute.ago
        )
        Aggregator::REDIS_POOL.with do |r|
          r.set("aggregator:source:binance:unhealthy", "1", ex: 30)
        end

        expect { described_class.new.perform }.not_to change(ExchangePollJob.jobs, :size)
      end
    end

    context "when a Source's latest Tick is stale and the Source is healthy" do
      it "enqueues a poll job (revival)" do
        Tick.create!(
          exchange:         "binance",
          pair:             "BTC-USD",
          price:            BigDecimal("67000"),
          quote_volume_24h: BigDecimal("1000"),
          source_ts:        1.minute.ago,
          ingested_ts:      1.minute.ago
        )

        expect { described_class.new.perform }.to change(ExchangePollJob.jobs, :size).by(1)
        expect(ExchangePollJob.jobs.last["args"]).to eq([ "binance" ])
      end
    end
  end
end
