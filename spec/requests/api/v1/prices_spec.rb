require "rails_helper"

RSpec.describe "GET /price/:pair", type: :request do
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

  context "with all three Sources healthy" do
    before do
      create_tick(exchange: "binance",  price: 67_430.50, volume: 4_200)
      create_tick(exchange: "coinbase", price: 67_434.00, volume: 3_100)
      create_tick(exchange: "kraken",   price: 67_432.05, volume: 2_700)
    end

    it "returns 200 with confidence ok and all 3 Sources used" do
      get "/price/BTC-USD"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["pair"]).to eq("BTC-USD")
      expect(body["confidence"]).to eq("ok")
      expect(body["sources_used"].map { |s| s["exchange"] }).to match_array(%w[binance coinbase kraken])
      expect(body["sources_rejected"]).to eq([])
      expect(body["window_seconds"]).to eq(10)
    end

    it "responds with Cache-Control: no-store so callers don't cache a body that ages instantly via as_of" do
      get "/price/BTC-USD"

      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "is open to cross-origin browser callers (CORS Access-Control-Allow-Origin echoes the request Origin)" do
      get "/price/BTC-USD", headers: { "Origin" => "https://example.com" }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*").or eq("https://example.com")
    end

    it "responds to a CORS preflight OPTIONS for /price/BTC-USD" do
      process :options, "/price/BTC-USD", headers: {
        "Origin"                         => "https://example.com",
        "Access-Control-Request-Method"  => "GET",
        "Access-Control-Request-Headers" => "Content-Type"
      }

      expect(response).to have_http_status(:no_content).or have_http_status(:ok)
      allowed_methods = response.headers["Access-Control-Allow-Methods"].to_s
      expect(allowed_methods).to include("GET")
    end

    it "renders vwap, per-source price, and per-source weight as decimal strings (never IEEE-754)" do
      get "/price/BTC-USD"

      body = JSON.parse(response.body)
      expect(body["vwap"]).to be_a(String)
      expect(body["vwap"]).to match(/\A\d+\.\d+\z/)
      body["sources_used"].each do |source|
        expect(source["price"]).to be_a(String),  "expected #{source['exchange']} price to be a String, got #{source['price'].class}"
        expect(source["weight"]).to be_a(String), "expected #{source['exchange']} weight to be a String, got #{source['weight'].class}"
      end
    end
  end

  context "when the pair is not in the supported set" do
    it "returns 404 with the unknown_pair envelope and supported_pairs echo" do
      get "/price/DOGE-USD"

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["pair"]).to eq("DOGE-USD")
      expect(body["error"]).to eq("unknown_pair")
      expect(body["supported_pairs"]).to eq([ "BTC-USD" ])
      expect(body).not_to have_key("detail")
    end

    it "returns 404 with a 'did you mean' hint when an upcased version of the pair would have matched" do
      get "/price/btc-usd"

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["pair"]).to eq("btc-usd")
      expect(body["error"]).to eq("unknown_pair")
      expect(body["detail"]).to eq("did you mean BTC-USD?")
    end
  end

  context "when fewer than MIN_SOURCES Sources are healthy" do
    before do
      create_tick(exchange: "binance", price: 67_430.50, volume: 4_200)
      # coinbase + kraken absent → only 1 healthy Source < MIN_SOURCES (2)
    end

    it "returns 503 with the insufficient_sources envelope and missing Sources merged in" do
      get "/price/BTC-USD"

      expect(response).to have_http_status(:service_unavailable)
      body = JSON.parse(response.body)
      expect(body["pair"]).to eq("BTC-USD")
      expect(body["error"]).to eq("insufficient_sources")
      expect(body["sources_used"]).to eq(1)
      expect(body["sources_required"]).to eq(2)
      missing = body["sources_rejected"].select { |r| r["reason"] == "unreachable" && r["detail"] == "no tick within window" }
      expect(missing.map { |r| r["exchange"] }).to match_array(%w[coinbase kraken])
    end
  end

  context "when one Source has produced no Tick within the window" do
    before do
      create_tick(exchange: "binance",  price: 67_430.50, volume: 4_200)
      create_tick(exchange: "coinbase", price: 67_434.00, volume: 3_100)
      # kraken absent entirely
    end

    it "returns 200 with confidence degraded_unreachable and synthesizes the missing-Source rejection" do
      get "/price/BTC-USD"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["confidence"]).to eq("degraded_unreachable")
      expect(body["sources_used"].map { |s| s["exchange"] }).to match_array(%w[binance coinbase])
      expect(body["sources_rejected"].size).to eq(1)
      rejection = body["sources_rejected"].first
      expect(rejection["exchange"]).to eq("kraken")
      expect(rejection["reason"]).to eq("unreachable")
      expect(rejection["detail"]).to eq("no tick within window")
    end
  end

  context "when one Source is a price outlier" do
    before do
      create_tick(exchange: "binance",  price: 67_430.50, volume: 4_200)
      create_tick(exchange: "coinbase", price: 67_434.00, volume: 3_100)
      create_tick(exchange: "kraken",   price: 0.01,      volume: 2_700)
    end

    it "returns 200 with confidence degraded_outlier and the outlier in sources_rejected" do
      get "/price/BTC-USD"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["confidence"]).to eq("degraded_outlier")
      expect(body["sources_used"].map { |s| s["exchange"] }).to match_array(%w[binance coinbase])
      expect(body["sources_rejected"].size).to eq(1)
      rejection = body["sources_rejected"].first
      expect(rejection["exchange"]).to eq("kraken")
      expect(rejection["reason"]).to eq("outlier")
    end
  end
end
