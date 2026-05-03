class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      db: db_status,
      redis: redis_status,
      sources_healthy: sources_healthy_count
    }
  end

  private

  # Count of Sources that have produced a Tick within the last
  # AGGREGATION_WINDOW — the same predicate the kernel uses to decide
  # which Sources contribute to a consensus. /healthz reports the
  # service's *output* readiness, not the polling-pipeline state.
  def sources_healthy_count
    Tick.where("ingested_ts > ?", Aggregator::Constants::AGGREGATION_WINDOW.ago)
        .distinct.count(:exchange)
  rescue StandardError
    0
  end

  def db_status
    ActiveRecord::Base.connection.execute("SELECT 1")
    "ok"
  rescue StandardError
    "error"
  end

  def redis_status
    Sidekiq.redis { |c| c.call("PING") } == "PONG" ? "ok" : "error"
  rescue StandardError
    "error"
  end
end
