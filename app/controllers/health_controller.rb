class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      db: db_status,
      redis: redis_status,
      sources_healthy: 0
    }
  end

  private

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
