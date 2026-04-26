module Aggregator
  class Tick
    include ActiveModel::Model
    include ActiveModel::Attributes

    attribute :exchange,         :string
    attribute :pair,             :string
    attribute :price,            :decimal
    attribute :quote_volume_24h, :decimal
    attribute :source_ts,        :datetime
    attribute :ingested_ts,      :datetime

    validates :exchange, :pair, :price, :quote_volume_24h, :source_ts, :ingested_ts,
              presence: true

    def ==(other)
      other.is_a?(Aggregator::Tick) &&
        exchange         == other.exchange &&
        pair             == other.pair &&
        price            == other.price &&
        quote_volume_24h == other.quote_volume_24h &&
        source_ts        == other.source_ts &&
        ingested_ts      == other.ingested_ts
    end
    alias_method :eql?, :==

    def hash
      [ exchange, pair, price, quote_volume_24h, source_ts, ingested_ts ].hash
    end
  end
end
