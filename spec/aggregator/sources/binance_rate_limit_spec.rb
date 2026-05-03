require "rails_helper"

RSpec.describe Aggregator::Sources::Binance, "rate limiting" do
  let(:adapter) { described_class.new }
  let(:happy_payload) do
    {
      "symbol" => "BTCUSDT",
      "lastPrice" => "67430.50000000",
      "quoteVolume" => "1350000000.00000000",
      "closeTime" => 1_777_824_000_000
    }.to_json
  end

  it "honors Retry-After on 429 by sleeping the header value, then retries" do
    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(
        { status: 429, headers: { "Retry-After" => "5" }, body: "" },
        { status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload }
      )

    expect(adapter).to receive(:sleep).with(5).once.and_return(nil)

    tick = adapter.fetch("BTC-USD")

    expect(tick).to be_a(Aggregator::Tick)
    expect(tick.price).to eq(BigDecimal("67430.50"))
  end
end
