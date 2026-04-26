module Aggregator
  module Constants
    POLLING_INTERVAL    = 2.0
    AGGREGATION_WINDOW  = 10.seconds
    STALENESS_SLO       = 10.seconds
    MAD_K               = 5.0
    MIN_SOURCES         = 2
    RETRY_BACKOFF_MS    = [ 250, 1_000, 4_000 ].freeze
    UNHEALTHY_TTL       = 30.seconds
  end
end
