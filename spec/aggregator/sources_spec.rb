require "rails_helper"

RSpec.describe Aggregator::Sources do
  describe "REGISTRY" do
    it "lists the v1 sources" do
      expect(described_class::REGISTRY).to eq(%w[binance coinbase])
    end

    it "is frozen" do
      expect(described_class::REGISTRY).to be_frozen
    end
  end

  describe ".adapter_for" do
    it "resolves a registered name to its adapter class" do
      expect(described_class.adapter_for("binance")).to eq(Aggregator::Sources::Binance)
      expect(described_class.adapter_for("coinbase")).to eq(Aggregator::Sources::Coinbase)
    end

    it "raises ArgumentError on an unknown name (allowlist enforced before const_get)" do
      expect { described_class.adapter_for("pretend_exchange") }
        .to raise_error(ArgumentError, /unknown source/)
    end
  end
end
