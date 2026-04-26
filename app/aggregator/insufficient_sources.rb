module Aggregator
  class InsufficientSources < StandardError
    attr_reader :sources_used, :sources_required, :sources_rejected

    def initialize(sources_used:, sources_required:, sources_rejected:)
      @sources_used     = sources_used
      @sources_required = sources_required
      @sources_rejected = sources_rejected
      super("insufficient_sources: #{sources_used} of #{sources_required} required")
    end
  end
end
