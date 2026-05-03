class PollerSupervisorJob
  include Sidekiq::Job

  sidekiq_options queue: :default, retry: 0

  SUPERVISOR_INTERVAL = 60

  def perform
    self.class.perform_in(SUPERVISOR_INTERVAL)

    Aggregator::Sources::REGISTRY.each do |name|
      next if Aggregator::Sources::Base.unhealthy?(name)

      latest = Tick.where(exchange: name).maximum(:ingested_ts)
      stale = latest.nil? || latest < Aggregator::Constants::AGGREGATION_WINDOW.ago

      ExchangePollJob.perform_async(name) if stale
    end
  end
end
