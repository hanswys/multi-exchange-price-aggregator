# Kicks the supervisor exactly once per Sidekiq server process boot. The
# supervisor itself is the source of truth for chain liveness (see
# docs/adr/0002-polling-chain-lifecycle.md): it iterates Sources::REGISTRY
# and enqueues an ExchangePollJob for any Source whose latest Tick is
# missing or older than AGGREGATION_WINDOW.
#
# Gated on Sidekiq.server? so this is a no-op in:
#   - test runs
#   - the web/Puma process
#   - `bin/rails console`
# Without that gate, every Rails process would seed its own polling
# pipeline and blow through Binance's rate-limit budget within minutes.
#
# Wrapped in `after_initialize` so the PollerSupervisorJob constant is
# resolved by Zeitwerk *after* eager loading completes — referencing it
# at top-level here would fail in development boot (constant not yet
# autoloadable).
module Aggregator
  module Poller
    def self.kick!
      PollerSupervisorJob.perform_async if Sidekiq.server?
    end
  end
end

Rails.application.config.after_initialize { Aggregator::Poller.kick! }
