redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }
  # Sidekiq's scheduled-poll interval defaults to ~5s, which would turn
  # ExchangePollJob.perform_in(2.seconds) into a real interval of 5–7s
  # and silently break the rate-limit math the adapters assume. Drop it
  # to ~1s so POLLING_INTERVAL = 2.0 actually means 2.0 ± ~0.5s. See
  # docs/adr/0002-polling-chain-lifecycle.md.
  config[:average_scheduled_poll_interval] = 1
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
