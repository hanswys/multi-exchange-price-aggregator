module Aggregator
  module Sources
    # Registered Sources for v1. Order is also the dashboard rendering
    # order and the supervisor's iteration order.
    #
    # Adding a Source: append the name here AND add the class file under
    # app/aggregator/sources/<name>.rb (the class name must be the
    # camelize of the entry — Aggregator::Sources.adapter_for resolves
    # by convention).
    REGISTRY = %w[binance coinbase].freeze

    def self.adapter_for(name)
      raise ArgumentError, "unknown source: #{name.inspect}" unless REGISTRY.include?(name)
      const_get(name.camelize)
    end
  end
end
