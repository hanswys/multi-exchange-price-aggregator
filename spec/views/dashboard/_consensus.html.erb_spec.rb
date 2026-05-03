require "rails_helper"

RSpec.describe "dashboard/_consensus.html.erb", type: :view do
  def aggregate(confidence)
    Aggregator::Aggregate.new(
      pair:             "BTC-USD",
      vwap:             BigDecimal("67432.18"),
      confidence:       confidence,
      sources_used:     [
        { exchange: "binance",  price: BigDecimal("67432.18"), weight: BigDecimal("1"), source_ts: Time.now.utc }
      ],
      sources_rejected: [],
      as_of:            Time.now.utc,
      window_seconds:   10
    )
  end

  it "renders the OK badge for confidence: ok" do
    render partial: "dashboard/consensus", locals: { agg: aggregate("ok") }
    expect(rendered).to have_css('.badge.ok', text: /OK/)
  end

  it "renders the warn badge for confidence: degraded_outlier" do
    render partial: "dashboard/consensus", locals: { agg: aggregate("degraded_outlier") }
    expect(rendered).to have_css('.badge.warn', text: /OUTLIER/)
  end

  it "renders the bad badge for confidence: degraded_unreachable" do
    render partial: "dashboard/consensus", locals: { agg: aggregate("degraded_unreachable") }
    expect(rendered).to have_css('.badge.bad', text: /UNREACHABLE/)
  end

  it "renders the consensus price" do
    render partial: "dashboard/consensus", locals: { agg: aggregate("ok") }
    expect(rendered).to include("67,432.18")
  end
end
