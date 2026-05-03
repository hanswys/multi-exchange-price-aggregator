require "rails_helper"

RSpec.describe "Dashboard", type: :system do
  it "renders the chrome bar with kernel constants and the dashboard landmarks" do
    visit "/"

    within "header[role='banner']" do
      expect(page).to have_text(/aggregator/i)
      expect(page).to have_text("poll 2.0s")
      expect(page).to have_text("window 10s")
      expect(page).to have_text("k=5.0")
    end

    expect(page).to have_css("main")
    expect(page).to have_css("[aria-live='polite']")
  end
end
