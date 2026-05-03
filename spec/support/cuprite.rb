require "capybara/rspec"
require "capybara/cuprite"

Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [ 1440, 900 ],
    headless:    true,
    timeout:     10,
    process_timeout: 20
  )
end

Capybara.javascript_driver = :cuprite
Capybara.default_driver    = :rack_test

RSpec.configure do |config|
  config.before(:each, type: :system) { driven_by(:rack_test) }
  config.before(:each, type: :system, js: true) { driven_by(:cuprite) }
end
