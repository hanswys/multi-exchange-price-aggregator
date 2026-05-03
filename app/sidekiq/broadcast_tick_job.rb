class BroadcastTickJob
  include Sidekiq::Job

  sidekiq_options queue: :broadcasts, retry: 0

  STREAM        = :price_BTC_USD
  TARGET        = "consensus_hero".freeze
  SENTINEL_KEY  = "broadcaster:in_flight".freeze
  # TTL must outlive one BROADCAST_INTERVAL gap so the live chain's next
  # perform refreshes the key before it expires; expires fast enough
  # that a dead chain releases the lock for the next boot. See ADR 0007.
  SENTINEL_TTL  = 3

  def self.in_flight?
    Aggregator::REDIS_POOL.with { |r| r.exists?(SENTINEL_KEY) }
  end

  def self.kick
    perform_async unless in_flight?
  end

  def perform
    Aggregator::REDIS_POOL.with { |r| r.set(SENTINEL_KEY, "1", ex: SENTINEL_TTL) }

    ticks = Tick.recent_values
    agg = Aggregator::Core.compute(ticks: ticks)

    Turbo::StreamsChannel.broadcast_update_to(
      STREAM,
      target:  TARGET,
      partial: "dashboard/consensus",
      locals:  { agg: agg }
    )
  rescue Aggregator::InsufficientSources
    last_good = Tick.recent_values(window: 60.seconds).first
    last_good_price = last_good&.price
    last_good_age   = last_good ? (Time.now.utc - last_good.source_ts).round(1) : nil

    Turbo::StreamsChannel.broadcast_update_to(
      STREAM,
      target:  TARGET,
      partial: "dashboard/state_error",
      locals:  { last_good_price: last_good_price, last_good_age: last_good_age }
    )
  ensure
    self.class.perform_in(Aggregator::Constants::BROADCAST_INTERVAL)
  end
end
