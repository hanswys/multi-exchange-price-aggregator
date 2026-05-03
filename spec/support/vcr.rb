require "vcr"
require "webmock/rspec"

VCR.configure do |c|
  c.cassette_library_dir = Rails.root.join("spec/fixtures/vcr").to_s
  c.hook_into :webmock
  c.configure_rspec_metadata!
  # Capybara's server health check + Cuprite's CDP traffic are localhost
  # connections that have nothing to do with exchange API replays.
  c.ignore_localhost = true
  c.ignore_hosts "127.0.0.1", "::1"
  c.default_cassette_options = {
    record: :none,
    match_requests_on: [ :method, :uri ]
  }
  # Strip noisy / IP-leaky response headers from recorded cassettes.
  c.before_record do |interaction|
    %w[Server X-Mbx-Uuid X-Mbx-Used-Weight X-Mbx-Used-Weight-1m Set-Cookie].each do |h|
      interaction.response.headers.delete(h)
    end
  end
end
