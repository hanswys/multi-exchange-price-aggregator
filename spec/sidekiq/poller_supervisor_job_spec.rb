require "rails_helper"

RSpec.describe PollerSupervisorJob, type: :job do
  # Helper: insert a Tick for one Source at a given age. The supervisor
  # iterates ALL Sources in REGISTRY, so every spec that wants to isolate
  # one Source must either freshen the others or accept their (correct)
  # cold-start enqueues. We freshen them.
  def tick_for(name, age:)
    Tick.create!(
      exchange:         name,
      pair:             "BTC-USD",
      price:            BigDecimal("67000"),
      quote_volume_24h: BigDecimal("1000"),
      source_ts:        age.ago,
      ingested_ts:      age.ago
    )
  end

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

    context "when every Source has a recent Tick (all chains alive)" do
      it "does not enqueue any poll jobs" do
        Aggregator::Sources::REGISTRY.each { |name| tick_for(name, age: 1.second) }

        expect { described_class.new.perform }.not_to change(ExchangePollJob.jobs, :size)
      end
    end

    context "when one Source's latest Tick is stale and that Source is Unhealthy" do
      it "does not enqueue a poll job for the Unhealthy Source (short-circuit)" do
        # Freshen every OTHER Source, leave binance with only a stale
        # tick. The supervisor uses Tick.where(...).maximum(:ingested_ts),
        # so adding a stale tick on top of a fresh one would be invisible —
        # the binance row must be the stale one outright.
        (Aggregator::Sources::REGISTRY - %w[binance]).each { |name| tick_for(name, age: 1.second) }
        tick_for("binance", age: 1.minute)
        Aggregator::REDIS_POOL.with do |r|
          r.set("aggregator:source:binance:unhealthy", "1", ex: 30)
        end

        expect { described_class.new.perform }.not_to change(ExchangePollJob.jobs, :size)
      end
    end

    context "when one Source's latest Tick is stale and that Source is healthy" do
      it "enqueues a poll job for that Source only (revival)" do
        (Aggregator::Sources::REGISTRY - %w[binance]).each { |name| tick_for(name, age: 1.second) }
        tick_for("binance", age: 1.minute)

        expect { described_class.new.perform }.to change(ExchangePollJob.jobs, :size).by(1)
        expect(ExchangePollJob.jobs.last["args"]).to eq([ "binance" ])
      end
    end
  end
end
