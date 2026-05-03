module Aggregator
  module Constants
    POLLING_INTERVAL    = 2.0
    BROADCAST_INTERVAL  = 1.0
    AGGREGATION_WINDOW  = 10.seconds
    STALENESS_SLO       = 10.seconds
    MAD_K               = 5.0
    MIN_SOURCES         = 2
    RETRY_BACKOFF_MS    = [ 250, 1_000, 4_000 ].freeze
    UNHEALTHY_TTL       = 30.seconds

    # HTTP timeouts for outbound exchange requests (Faraday).
    HTTP_OPEN_TIMEOUT   = 2
    HTTP_READ_TIMEOUT   = 5

    # Cap on Retry-After honoring. A hostile or misconfigured server could
    # return a Retry-After larger than this; we treat anything bigger as
    # "open the circuit now" rather than pinning a Sidekiq worker for
    # minutes. Tuned to one full UNHEALTHY_TTL cycle.
    RETRY_AFTER_MAX_S   = 30
  end
end
