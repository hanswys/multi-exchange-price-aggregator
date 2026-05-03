require "rails_helper"

RSpec.describe Aggregator::Sources::Binance, "response parsing and pair validation" do
  let(:adapter) { described_class.new }

  describe "unknown canonical pair" do
    it "raises ArgumentError without making any HTTP request" do
      stub_request(:get, %r{api\.binance\.com}).to_return(status: 200, body: "{}")

      expect {
        adapter.fetch("DOGE-USD")
      }.to raise_error(ArgumentError, /binance does not support pair: "DOGE-USD"/)

      expect(WebMock).not_to have_requested(:get, %r{api\.binance\.com})
    end
  end

  describe "malformed 200 response" do
    it "raises MalformedResponse and does not retry when a required field is missing" do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { "symbol" => "BTCUSDT" }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing field "lastPrice"/)

      expect(WebMock).to have_requested(:get, %r{api\.binance\.com/api/v3/ticker/24hr}).once
    end

    it "raises MalformedResponse when the body is not a JSON object" do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "[]")

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /not a JSON object/)
    end
  end
end
