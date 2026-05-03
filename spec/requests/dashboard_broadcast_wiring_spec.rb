require "rails_helper"

RSpec.describe "Dashboard broadcast wiring", type: :request do
  it "subscribes the dashboard page to the same stream BroadcastTickJob broadcasts to" do
    expected_stream = Turbo::StreamsChannel.signed_stream_name(BroadcastTickJob::STREAM)

    get "/", params: { state: :ok }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(expected_stream),
      "expected dashboard to render a turbo-cable-stream-source for #{BroadcastTickJob::STREAM.inspect} " \
      "but the signed stream name was not found in the response body"
  end

  it "renders #consensus_hero as the broadcast target" do
    get "/", params: { state: :ok }
    expect(response.body).to match(/id=["']consensus_hero["']/)
  end
end
