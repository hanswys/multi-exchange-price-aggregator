module Aggregator
  module Sources
    # Raised after the retry budget is exhausted. The Source has just been
    # marked Unhealthy as a side effect — see Base#fetch.
    class Unreachable < Error; end
  end
end
