require "rails_helper"

RSpec.describe "GET /", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.utc(2026, 4, 26, 12, 0, 0) }

  def create_tick(exchange:, price:, volume: 1_000, age: 1)
    Tick.create!(
      exchange:         exchange,
      pair:             "BTC-USD",
      price:            BigDecimal(price.to_s),
      quote_volume_24h: BigDecimal(volume.to_s),
      source_ts:        now - age,
      ingested_ts:      now - age
    )
  end

  around { |ex| travel_to(now) { ex.run } }

  context "with no Ticks (cold boot)" do
    it "renders the empty state with a placeholder consensus and the waiting copy" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-state="empty"')
      expect(response.body).to include("——,———.——")
      expect(response.body).to include("Waiting for first tick from each source")
    end

    it "still renders one row per registered Source with — placeholder" do
      get "/"

      Aggregator::Sources::REGISTRY.each do |name|
        expect(response.body).to include(%(data-source="#{name}"))
      end
    end
  end

  context "with all three Sources healthy" do
    before do
      create_tick(exchange: "binance",  price: 67_430.50, volume: 4_200)
      create_tick(exchange: "coinbase", price: 67_434.00, volume: 3_100)
      create_tick(exchange: "kraken",   price: 67_432.05, volume: 2_700)
    end

    it "renders the OK consensus state with the formatted vwap" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-state="ok"')
      expect(response.body).to match(/OK · 3 sources/)
      # vwap is the volume-weighted consensus across the three ticks. We
      # don't pin the exact number — the kernel owns that math. We pin the
      # formatting (comma-thousands, 2 decimals) and the 67,4XX.XX shape.
      expect(response.body).to match(/67,4\d\d\.\d\d/)
    end

    it "renders one source row per registered Source with formatted price and weight" do
      get "/"

      Aggregator::Sources::REGISTRY.each do |name|
        expect(response.body).to match(/data-source="#{name}"[^>]*>.*?#{name}/m)
      end
      expect(response.body).to match(/\d{1,3}(?:,\d{3})?\.\d{2}/)
      expect(response.body).to match(/\d+\.\d%/)
    end

    it "shows no rejection rows when all three Sources contributed" do
      get "/"

      expect(response.body).to include("no rejections in window")
    end
  end

  context "with two Sources healthy and one missing" do
    before do
      create_tick(exchange: "binance",  price: 67_430.50, volume: 4_200)
      create_tick(exchange: "coinbase", price: 67_434.00, volume: 3_100)
      # kraken absent — synthesized as `unreachable`
    end

    it "renders the partial state with DEGRADED · UNREACHABLE" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-state="partial"')
      expect(response.body).to include("DEGRADED · UNREACHABLE")
    end

    it "marks the missing Source row with the bad style and shows the rejection row" do
      get "/"

      expect(response.body).to match(/<tr class="src-row bad" data-source="kraken"/)
      expect(response.body).to match(/<span class="ex">kraken<\/span>\s*<span class="reason unreachable">unreachable<\/span>/)
    end
  end

  context "with fewer than MIN_SOURCES healthy and a last-good Tick within 60s" do
    before do
      create_tick(exchange: "binance", price: 67_500.00, volume: 4_200, age: 1)
    end

    it "renders the error state with the insufficient-sources copy" do
      get "/"

      expect(response).to have_http_status(:ok) # the dashboard always 200s; the JSON API is what 503s
      expect(response.body).to include('data-state="error"')
      expect(response.body).to match(/Insufficient sources — only 1 of 3 healthy/)
    end

    it "shows the last-good price and age subtext from the wider 60s window" do
      get "/"

      expect(response.body).to include("last good price was $67,500.00")
      expect(response.body).to match(/\d+\.\d{1,2}s ago/)
    end
  end

  context "with the ?state= override" do
    it "renders the disconnect chrome in the test environment" do
      get "/?state=disconnect"

      expect(response.body).to include('data-state="disconnect"')
      expect(response.body).to include("RECONNECTING…")
    end

    it "ignores the override in production and falls back to inferred state" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      get "/?state=disconnect"

      # No fresh ticks → inferred :empty, not :disconnect
      expect(response.body).to include('data-state="empty"')
      expect(response.body).not_to include("RECONNECTING…")
    end
  end
end
