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

  it "falls back to RETRY_BACKOFF_MS when 429 has no Retry-After header" do
    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(
        { status: 429, body: "" },
        { status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload }
      )

    expect(adapter).to receive(:sleep).with(0.25).once.and_return(nil)

    expect(adapter.fetch("BTC-USD")).to be_a(Aggregator::Tick)
  end

  it "ignores HTTP-date Retry-After (intentionally not parsed) and falls back to backoff" do
    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(
        { status: 429, headers: { "Retry-After" => "Wed, 21 Oct 2026 07:28:00 GMT" }, body: "" },
        { status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload }
      )

    expect(adapter).to receive(:sleep).with(0.25).once.and_return(nil)

    expect(adapter.fetch("BTC-USD")).to be_a(Aggregator::Tick)
  end

  it "ignores Retry-After larger than RETRY_AFTER_MAX_S so a hostile server can't pin a worker" do
    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(
        { status: 429, headers: { "Retry-After" => (Aggregator::Constants::RETRY_AFTER_MAX_S + 1).to_s }, body: "" },
        { status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload }
      )

    expect(adapter).to receive(:sleep).with(0.25).once.and_return(nil)

    expect(adapter.fetch("BTC-USD")).to be_a(Aggregator::Tick)
  end

  it "raises Unreachable and opens the circuit when every attempt is 429" do
    stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
      .to_return(status: 429, headers: { "Retry-After" => "1" }, body: "")
    allow(adapter).to receive(:sleep)

    expect { adapter.fetch("BTC-USD") }.to raise_error(Aggregator::Sources::Unreachable)
    Aggregator::REDIS_POOL.with do |r|
      expect(r.exists?("aggregator:source:binance:unhealthy")).to be(true)
    end
  end
end
