require "rails_helper"

RSpec.describe Aggregator::Sources::Base do
  describe ".unhealthy?(name)" do
    it "is false when the unhealthy key is absent in Redis" do
      expect(described_class.unhealthy?("binance")).to be(false)
    end

    it "is true when the unhealthy key is present in Redis" do
      Aggregator::REDIS_POOL.with do |r|
        r.set("aggregator:source:binance:unhealthy", "1", ex: 30)
      end
      expect(described_class.unhealthy?("binance")).to be(true)
    end

    it "fails open (returns false) when Redis is unreachable" do
      broken_pool = ConnectionPool.new(size: 1) do
        Object.new.tap do |o|
          def o.with
            yield self
          end

          def o.exists?(_key)
            raise Redis::CannotConnectError, "no redis"
          end
        end
      end
      # The double above ignores #with's block and yields itself — simpler
      # than wiring up a real broken Redis. Pass it via the keyword arg.
      expect(described_class.unhealthy?("binance", redis_pool: broken_pool)).to be(false)
    end
  end
end
