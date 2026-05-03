module Aggregator
  module Sources
    # Base class for adapter failures. Callers (poll job, rake task,
    # supervisor) typically rescue this; the subclasses are for code that
    # wants to discriminate between failure modes.
    #
    # Subclasses live alongside this file:
    #   - Aggregator::Sources::Unhealthy
    #   - Aggregator::Sources::Unreachable
    #   - Aggregator::Sources::MalformedResponse
    class Error < StandardError; end
  end
end
