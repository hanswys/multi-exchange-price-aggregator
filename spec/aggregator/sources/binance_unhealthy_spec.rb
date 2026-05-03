require "rails_helper"

RSpec.describe Aggregator::Sources::Binance, "circuit short-circuit" do
  let(:adapter) { described_class.new }
  let(:unhealthy_key) { "aggregator:source:binance:unhealthy" }

  it "raises Unhealthy without making any HTTP request when the circuit is open" do
    Aggregator::REDIS_POOL.with do |r|
      r.set(unhealthy_key, "1", ex: Aggregator::Constants::UNHEALTHY_TTL.to_i)
    end

    stub_request(:get, %r{api\.binance\.com}).to_return(status: 200, body: "{}")

    expect {
      adapter.fetch("BTC-USD")
    }.to raise_error(Aggregator::Sources::Unhealthy, /binance is unhealthy/)

    expect(WebMock).not_to have_requested(:get, %r{api\.binance\.com})
  end

  it "fetches normally once the unhealthy key has expired" do
    happy_payload = {
      "lastPrice" => "67430.50000000",
      "quoteVolume" => "1350000000.00000000",
      "closeTime" => 1_777_824_000_000
    }.to_json

    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload)

    # Key was never set — Source is healthy.
    tick = adapter.fetch("BTC-USD")
    expect(tick).to be_a(Aggregator::Tick)
  end
end
