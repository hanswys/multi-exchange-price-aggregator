module Api
  module V1
    class PricesController < BaseController
      def show
        return render_unknown_pair unless Aggregator::Sources::CANONICAL_PAIRS.include?(params[:pair])

        ticks   = Tick.recent_values
        missing = missing_rejections(ticks)

        aggregate = Aggregator::Core.compute(ticks: ticks)
        render json: aggregate.to_h.merge(sources_rejected: aggregate.sources_rejected + missing)
      rescue Aggregator::InsufficientSources => error
        render_insufficient_sources(error, missing)
      end

      private

      # Synthesize an `unreachable` Rejection for each REGISTRY Source that
      # produced no Tick in the window. The kernel only rejects Ticks it
      # sees; the API surface promises a row per known Source. See
      # docs/adr/0006-missing-source-rejection-injection.md.
      def missing_rejections(ticks)
        seen = ticks.map(&:exchange).uniq
        (Aggregator::Sources::REGISTRY - seen).map do |name|
          { exchange: name, reason: "unreachable", detail: "no tick within window" }
        end
      end

      def render_unknown_pair
        envelope = {
          pair:            params[:pair],
          error:           "unknown_pair",
          supported_pairs: Aggregator::Sources::CANONICAL_PAIRS
        }
        upcased = params[:pair].to_s.upcase
        if upcased != params[:pair] && Aggregator::Sources::CANONICAL_PAIRS.include?(upcased)
          envelope[:detail] = "did you mean #{upcased}?"
        end
        render json: envelope, status: :not_found
      end

      def render_insufficient_sources(error, missing)
        envelope = {
          pair:             params[:pair],
          error:            "insufficient_sources",
          sources_used:     error.sources_used,
          sources_required: error.sources_required,
          sources_rejected: error.sources_rejected + missing
        }
        render json: envelope, status: :service_unavailable
      end
    end
  end
end
