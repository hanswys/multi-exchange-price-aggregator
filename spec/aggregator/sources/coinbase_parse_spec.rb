require "rails_helper"

RSpec.describe Aggregator::Sources::Coinbase, "response parsing and pair validation" do
  let(:adapter) { described_class.new }
  let(:endpoint_url) { "https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD" }

  let(:happy_body) do
    {
      "product_id" => "BTC-USD",
      "price" => "67432.18",
      "volume_24h" => "12000.00000000",
      "status" => "online"
    }.to_json
  end

  let(:happy_headers) do
    { "Content-Type" => "application/json", "Date" => "Sun, 03 May 2026 16:00:00 GMT" }
  end

  describe "unknown canonical pair" do
    it "raises ArgumentError without making any HTTP request" do
      stub_request(:get, %r{api\.coinbase\.com}).to_return(status: 200, body: "{}")

      expect {
        adapter.fetch("DOGE-USD")
      }.to raise_error(ArgumentError, /coinbase does not support pair: "DOGE-USD"/)

      expect(WebMock).not_to have_requested(:get, %r{api\.coinbase\.com})
    end
  end

  describe "computed quote_volume_24h" do
    it "multiplies base volume_24h by price (Coinbase exposes base volume only)" do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, headers: happy_headers, body: happy_body)

      tick = adapter.fetch("BTC-USD")

      expect(tick.quote_volume_24h)
        .to eq(BigDecimal("12000.00000000") * BigDecimal("67432.18"))
    end
  end

  describe "Date response header (source_ts anchor)" do
    it "uses the HTTP Date header as source_ts" do
      stub_request(:get, endpoint_url)
        .to_return(
          status: 200,
          headers: { "Date" => "Sun, 03 May 2026 16:00:00 GMT" },
          body: happy_body
        )

      tick = adapter.fetch("BTC-USD")

      expect(tick.source_ts).to eq(Time.utc(2026, 5, 3, 16, 0, 0))
    end

    it "raises MalformedResponse when Date header is absent" do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: happy_body)

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing Date response header/)
    end

    it "raises MalformedResponse when Date header is unparseable" do
      stub_request(:get, endpoint_url)
        .to_return(
          status: 200,
          headers: { "Date" => "not-a-real-date" },
          body: happy_body
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /unparseable Date header/)
    end
  end

  describe "malformed 200 response" do
    it "raises MalformedResponse and does not retry when a required field is missing" do
      stub_request(:get, endpoint_url)
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "product_id" => "BTC-USD" }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing field "price"/)

      expect(WebMock).to have_requested(:get, endpoint_url).once
    end

    it "raises MalformedResponse when the body is not a JSON object" do
      stub_request(:get, endpoint_url)
        .to_return(status: 200, headers: happy_headers, body: "[]")

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /not a JSON object/)
    end

    it "raises MalformedResponse when price is not a valid number" do
      stub_request(:get, endpoint_url)
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "price" => "not-a-number", "volume_24h" => "1" }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /malformed payload/)
    end

    it "raises MalformedResponse when volume_24h is not a valid number" do
      stub_request(:get, endpoint_url)
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "price" => "1", "volume_24h" => "garbage" }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /malformed payload/)
    end
  end
end
