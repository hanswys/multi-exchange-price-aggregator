require "rails_helper"

RSpec.describe "GET /healthz", type: :request do
  it "reports sources_healthy as the count of distinct Sources with a Tick in the last AGGREGATION_WINDOW" do
    Tick.create!(
      exchange:         "binance",
      pair:             "BTC-USD",
      price:            BigDecimal("67000"),
      quote_volume_24h: BigDecimal("1000"),
      source_ts:        1.second.ago,
      ingested_ts:      1.second.ago
    )
    # Stale Tick — older than AGGREGATION_WINDOW; should NOT be counted.
    Tick.create!(
      exchange:         "kraken",
      pair:             "BTC-USD",
      price:            BigDecimal("67000"),
      quote_volume_24h: BigDecimal("1000"),
      source_ts:        1.minute.ago,
      ingested_ts:      1.minute.ago
    )

    get "/healthz"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["sources_healthy"]).to eq(1)
  end

  it "stays 200 even when sources_healthy is 0 (DB/Redis liveness is the status signal)" do
    get "/healthz"

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["sources_healthy"]).to eq(0)
    expect(body["status"]).to eq("ok")
  end
end
