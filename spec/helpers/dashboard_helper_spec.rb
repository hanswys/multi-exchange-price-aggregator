require "rails_helper"

RSpec.describe DashboardHelper, type: :helper do
  describe "#format_price" do
    it "formats with comma thousands and 2 decimals" do
      expect(helper.format_price(BigDecimal("67432.18"))).to eq("67,432.18")
    end

    it "rounds to 2 decimals" do
      expect(helper.format_price(BigDecimal("67432.187"))).to eq("67,432.19")
    end

    it "pads short fractions" do
      expect(helper.format_price(BigDecimal("100.5"))).to eq("100.50")
    end

    it "handles values under 1000 without commas" do
      expect(helper.format_price(BigDecimal("42.00"))).to eq("42.00")
    end
  end

  describe "#format_weight" do
    it "renders a fractional weight as 1-decimal percent" do
      expect(helper.format_weight(BigDecimal("0.4231"))).to eq("42.3%")
    end

    it "renders 1.0 as 100.0%" do
      expect(helper.format_weight(BigDecimal("1.0"))).to eq("100.0%")
    end
  end

  describe "#format_age" do
    it "uses 2 decimals under 10s" do
      expect(helper.format_age(1.21)).to eq("1.21s")
    end

    it "uses 1 decimal at 10s and above" do
      expect(helper.format_age(12.4)).to eq("12.4s")
    end
  end

  describe "#format_clock_utc" do
    it "renders 24h UTC clock with seconds" do
      t = Time.utc(2026, 4, 25, 23, 42, 0)
      expect(helper.format_clock_utc(t)).to eq("23:42:00 UTC")
    end
  end
end
