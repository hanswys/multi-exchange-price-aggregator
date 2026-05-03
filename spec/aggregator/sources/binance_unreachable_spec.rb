require "rails_helper"

RSpec.describe Aggregator::Sources::Binance, "retry exhaustion" do
  let(:adapter) { described_class.new }
  let(:unhealthy_key) { "aggregator:source:binance:unhealthy" }

  context "when every attempt returns a 5xx" do
    before do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_return(status: 503, body: "")
    end

    it "sleeps according to RETRY_BACKOFF_MS, raises Unreachable, and marks the Source unhealthy" do
      sleeps = []
      allow(adapter).to receive(:sleep) { |s| sleeps << s }

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::Unreachable)

      expect(sleeps).to eq([ 0.25, 1.0, 4.0 ])
      expect(WebMock).to have_requested(:get, %r{api\.binance\.com/api/v3/ticker/24hr}).times(4)

      Aggregator::REDIS_POOL.with do |r|
        expect(r.exists?(unhealthy_key)).to be(true)
        expect(r.ttl(unhealthy_key)).to be_between(1, Aggregator::Constants::UNHEALTHY_TTL.to_i)
      end
    end
  end

  context "when every attempt fails with a connection error" do
    before do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_raise(Faraday::ConnectionFailed.new("connection refused"))
    end

    it "raises Unreachable after exhausting RETRY_BACKOFF_MS" do
      allow(adapter).to receive(:sleep)

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::Unreachable, /connection refused/)

      expect(WebMock).to have_requested(:get, %r{api\.binance\.com/api/v3/ticker/24hr}).times(4)
      Aggregator::REDIS_POOL.with do |r|
        expect(r.exists?(unhealthy_key)).to be(true)
      end
    end
  end

  context "when every attempt times out" do
    before do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_raise(Faraday::TimeoutError.new("read timed out"))
    end

    it "raises Unreachable and marks the Source unhealthy" do
      allow(adapter).to receive(:sleep)

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::Unreachable, /timed out/)

      Aggregator::REDIS_POOL.with do |r|
        expect(r.exists?(unhealthy_key)).to be(true)
      end
    end
  end

  context "transient failure followed by success" do
    let(:happy_payload) do
      {
        "lastPrice" => "67430.50000000",
        "quoteVolume" => "1350000000.00000000",
        "closeTime" => 1_777_824_000_000
      }.to_json
    end

    it "recovers from a single 5xx and returns a Tick on the retry" do
      stub_request(:get, %r{api\.binance\.com/api/v3/ticker/24hr})
        .to_return(
          { status: 503, body: "" },
          { status: 200, headers: { "Content-Type" => "application/json" }, body: happy_payload }
        )

      expect(adapter).to receive(:sleep).with(0.25).once.and_return(nil)

      tick = adapter.fetch("BTC-USD")
      expect(tick).to be_a(Aggregator::Tick)
      expect(tick.price).to eq(BigDecimal("67430.50"))

      Aggregator::REDIS_POOL.with do |r|
        expect(r.exists?(unhealthy_key)).to be(false)
      end
    end
  end
end
