require "mock_redis"
require "connection_pool"

# Replace the production Redis pool with a MockRedis-backed pool for the
# test suite. MockRedis is a pure-Ruby fake that honors TTL semantics, so
# specs that assert "the key expires after UNHEALTHY_TTL" execute the
# real behavior rather than asserting against a stub.
#
# A single MockRedis instance is wrapped in the pool so every checkout
# sees the same in-memory store — flushed before each example.
Aggregator.send(:remove_const, :REDIS_POOL) if Aggregator.const_defined?(:REDIS_POOL, false)

mock_redis = MockRedis.new
Aggregator::REDIS_POOL = ConnectionPool.new(size: 1) { mock_redis }

RSpec.configure do |config|
  config.before(:each) do
    Aggregator::REDIS_POOL.with(&:flushdb)
  end
end
