class ExchangePollJob
  include Sidekiq::Job

  sidekiq_options queue: :polling, retry: 0

  def perform(name)
    adapter = Aggregator::Sources.adapter_for(name).new
    begin
      porotick = adapter.fetch("BTC-USD")
      Tick.create!(porotick.attributes)
    rescue Aggregator::Sources::Unreachable, Aggregator::Sources::Unhealthy => e
      Rails.logger.warn("[poll #{name}] chain killed — #{e.class.name.demodulize}: #{e.message}")
      return
    rescue Aggregator::Sources::MalformedResponse => e
      Rails.logger.error("[poll #{name}] MalformedResponse — chain continues: #{e.message}")
    end
    self.class.perform_in(Aggregator::Constants::POLLING_INTERVAL, name)
  end
end
