# Kicks the Broadcast chain on Sidekiq boot. The chain self-reschedules
# at BROADCAST_INTERVAL (1s). Idempotency is enforced by
# BroadcastTickJob.kick — it consults the Redis sentinel
# (`broadcaster:in_flight`) and is a no-op if a chain is already alive.
# See docs/adr/0007-broadcast-chain-design.md.
#
# Gated on Sidekiq.server? so this is a no-op in:
#   - test runs
#   - the web/Puma process
#   - `bin/rails console`
module Aggregator
  module Broadcaster
    def self.kick!
      BroadcastTickJob.kick if Sidekiq.server?
    end
  end
end

Rails.application.config.after_initialize { Aggregator::Broadcaster.kick! }
