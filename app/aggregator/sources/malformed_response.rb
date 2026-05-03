module Aggregator
  module Sources
    # Raised when the Source returns 200 but the body cannot be parsed
    # into a valid Tick. Distinct from Unreachable because malformed
    # responses are not transient — retrying will not help.
    class MalformedResponse < Error; end
  end
end
