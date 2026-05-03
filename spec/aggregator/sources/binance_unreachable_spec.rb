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

      Aggregator::REDIS_POOL.with do |r|
        expect(r.exists?(unhealthy_key)).to be(true)
      end
    end
  end
end
