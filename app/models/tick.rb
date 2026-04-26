class Tick < ApplicationRecord
  self.implicit_order_column = "ingested_ts"

  validates :exchange, :pair, :price, :quote_volume_24h, :source_ts, :ingested_ts,
            presence: true

  def to_value
    Aggregator::Tick.new(
      exchange:         exchange,
      pair:             pair,
      price:            price,
      quote_volume_24h: quote_volume_24h,
      source_ts:        source_ts,
      ingested_ts:      ingested_ts
    )
  end

  def self.recent_values(window: Aggregator::Constants::AGGREGATION_WINDOW)
    where("ingested_ts > ?", window.ago).order(ingested_ts: :desc).map(&:to_value)
  end
end
