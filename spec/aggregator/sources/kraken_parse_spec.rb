require "rails_helper"

RSpec.describe Aggregator::Sources::Kraken, "response parsing and pair validation" do
  let(:adapter) { described_class.new }
  let(:endpoint_url) { "https://api.kraken.com/0/public/Ticker" }

  let(:happy_ticker) do
    {
      "a" => [ "67432.30000", "1", "1.000" ],
      "b" => [ "67432.10000", "2", "2.000" ],
      "c" => [ "67432.20000", "0.00100000" ],
      "v" => [ "500.50000000", "12000.00000000" ],
      "p" => [ "67400.00000000", "67500.00000000" ],
      "t" => [ 1234, 56789 ],
      "l" => [ "67000.00000", "66800.00000" ],
      "h" => [ "68000.00000", "68200.00000" ],
      "o" => "67500.00000"
    }
  end

  let(:happy_body) do
    { "error" => [], "result" => { "XXBTZUSD" => happy_ticker } }.to_json
  end

  let(:happy_headers) do
    { "Content-Type" => "application/json", "Date" => "Sun, 03 May 2026 16:00:00 GMT" }
  end

  describe "unknown canonical pair" do
    it "raises ArgumentError without making any HTTP request" do
      stub_request(:get, %r{api\.kraken\.com}).to_return(status: 200, body: "{}")

      expect {
        adapter.fetch("DOGE-USD")
      }.to raise_error(ArgumentError, /kraken does not support pair: "DOGE-USD"/)

      expect(WebMock).not_to have_requested(:get, %r{api\.kraken\.com})
    end
  end

  describe "computed quote_volume_24h" do
    it "multiplies 24h base volume (v[1]) by 24h VWAP (p[1])" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(status: 200, headers: happy_headers, body: happy_body)

      tick = adapter.fetch("BTC-USD")

      expect(tick.quote_volume_24h)
        .to eq(BigDecimal("12000.00000000") * BigDecimal("67500.00000000"))
    end
  end

  describe "Kraken's 200 + non-empty error envelope" do
    it "raises MalformedResponse with the API error string interpolated" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [ "EQuery:Unknown asset pair" ], "result" => {} }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /API error — EQuery:Unknown asset pair/)
    end

    it "raises MalformedResponse and does not retry (Source is reachable)" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [ "EService:Busy" ], "result" => {} }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse)

      expect(WebMock).to have_requested(:get, endpoint_url).with(query: { pair: "XXBTZUSD" }).once
    end
  end

  describe "result-key lookup by sent native symbol" do
    it "raises MalformedResponse if Kraken responds under a different key (e.g. an altname rewrite)" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          # Same ticker block but keyed by the altname `XBTUSD` instead of
          # the X/Z-prefixed `XXBTZUSD`. Defensive assertion: see ADR 0004.
          body: { "error" => [], "result" => { "XBTUSD" => happy_ticker } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing native key "XXBTZUSD"/)
    end

    it "raises MalformedResponse when the result block is missing entirely" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [] }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing or non-object result/)
    end

    it "raises MalformedResponse when the inner ticker block is not an object" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => "not-a-hash" } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /ticker block for XXBTZUSD was not an object/)
    end

    it "raises MalformedResponse when the inner ticker block is null" do
      # Distinct from the not-a-hash case above: result.fetch returns nil
      # (key exists, value is null), which would slip past a naive
      # missing-key check. The is_a?(Hash) guard catches it.
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => nil } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /ticker block for XXBTZUSD was not an object/)
    end
  end

  describe "tolerant interpretation of the error envelope" do
    it "treats a null `error` field as success (proceeds to result parsing)" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => nil, "result" => { "XXBTZUSD" => happy_ticker } }.to_json
        )

      expect { adapter.fetch("BTC-USD") }.not_to raise_error
    end

    it "treats a missing `error` field as success" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "result" => { "XXBTZUSD" => happy_ticker } }.to_json
        )

      expect { adapter.fetch("BTC-USD") }.not_to raise_error
    end

    it "treats a string-typed `error` field as success (only the documented array shape is honored)" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => "EAPI:something", "result" => { "XXBTZUSD" => happy_ticker } }.to_json
        )

      expect { adapter.fetch("BTC-USD") }.not_to raise_error
    end

    it "truncates an unbounded error string in the exception message" do
      huge = "X" * 10_000
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [ huge ], "result" => {} }.to_json
        )

      expect { adapter.fetch("BTC-USD") }.to raise_error(Aggregator::Sources::MalformedResponse) { |e|
        expect(e.message.length).to be < 400
      }
    end
  end

  describe "Date response header (source_ts anchor)" do
    it "uses the HTTP Date header as source_ts" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
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
        .with(query: { pair: "XXBTZUSD" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: happy_body)

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing Date response header/)
    end

    it "raises MalformedResponse when Date header is unparseable" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
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
    it "raises MalformedResponse when the body is not a JSON object" do
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(status: 200, headers: happy_headers, body: "[]")

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /not a JSON object/)
    end

    it "raises MalformedResponse when a required field (c) is missing from the ticker block" do
      ticker_without_c = happy_ticker.dup.tap { |h| h.delete("c") }
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_without_c } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /missing field "c"/)
    end

    it "raises MalformedResponse when v is not a length-2+ array" do
      ticker_bad_v = happy_ticker.merge("v" => [ "500.50000000" ]) # only one element
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_bad_v } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /field "v" is not a length-2\+ array/)
    end

    it "raises MalformedResponse when c[0] is not a valid number" do
      ticker_bad_price = happy_ticker.merge("c" => [ "not-a-number", "0.001" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_bad_price } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /malformed payload/)
    end

    it "raises MalformedResponse when p[1] is not a valid number" do
      ticker_bad_vwap = happy_ticker.merge("p" => [ "67400", "garbage" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_bad_vwap } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /malformed payload/)
    end

    it "raises MalformedResponse when v[1] is null (Kraken occasionally null-fills array slots)" do
      ticker_null_vol = happy_ticker.merge("v" => [ "500.50000000", nil ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_null_vol } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /malformed payload/)
    end
  end

  describe "non-finite numeric guards" do
    # BigDecimal("NaN"), BigDecimal("Infinity"), BigDecimal("-Infinity") all
    # parse without raising — the explicit .finite? check is the only thing
    # standing between a poison upstream and a NaN-tainted Aggregate that
    # silently corrupts every Source's MAD outlier and weighted-mean math.
    it "rejects NaN price" do
      ticker_nan = happy_ticker.merge("c" => [ "NaN", "0.001" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_nan } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /non-finite numeric/)
    end

    it "rejects Infinity in 24h VWAP" do
      ticker_inf = happy_ticker.merge("p" => [ "67400", "Infinity" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_inf } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /non-finite numeric/)
    end

    it "rejects a zero-or-negative price (no real BTC market quotes 0)" do
      ticker_zero_price = happy_ticker.merge("c" => [ "0", "0.001" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_zero_price } }.to_json
        )

      expect {
        adapter.fetch("BTC-USD")
      }.to raise_error(Aggregator::Sources::MalformedResponse, /non-positive price/)
    end

    it "allows zero quote-volume (kernel handles this — see core_zero_volume_spec.rb)" do
      ticker_zero_vol = happy_ticker.merge("v" => [ "0", "0" ])
      stub_request(:get, endpoint_url)
        .with(query: { pair: "XXBTZUSD" })
        .to_return(
          status: 200,
          headers: happy_headers,
          body: { "error" => [], "result" => { "XXBTZUSD" => ticker_zero_vol } }.to_json
        )

      expect { adapter.fetch("BTC-USD") }.not_to raise_error
    end
  end
end
