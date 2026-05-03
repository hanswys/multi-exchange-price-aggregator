# Public read-only JSON API. The /price/* endpoint is intentionally
# open to any origin — there is no auth, no cookies, no credentials.
# Restricting origins would be theatre.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/price/*", headers: :any, methods: [ :get ]
  end
end
