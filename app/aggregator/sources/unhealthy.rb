module Aggregator
  module Sources
    # Raised at the start of #fetch when the Source's circuit is already
    # open. No HTTP request is made. The Source becomes healthy again
    # automatically when the Redis key expires after UNHEALTHY_TTL.
    class Unhealthy < Error; end
  end
end
