require "connection_pool"

# Application-owned Redis pool used by Aggregator::Sources::Base for
# per-Source health state ("unhealthy" keys with TTL = UNHEALTHY_TTL).
#
# Deliberately separate from Sidekiq.redis: this pool is read by the rake
# task, the future supervisor job, and /healthz — none of which should
# require Sidekiq to be loaded. See docs/adr/0001-source-adapter-fetch-contract.md.
#
# In test, we substitute a MockRedis-backed pool in spec/support/aggregator_redis.rb
# so the suite stays hermetic.
module Aggregator
  REDIS_POOL = ConnectionPool.new(size: 5, timeout: 1) do
    Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
  end
end
