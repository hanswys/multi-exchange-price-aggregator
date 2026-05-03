require "sidekiq/test_api"

# `:fake` queues jobs into in-memory arrays (`SomeJob.jobs`) without
# executing them. Tests assert against those arrays.
#
# DO NOT enter `:inline` mode here. Self-rescheduling jobs
# (ExchangePollJob, PollerSupervisorJob) call `perform_in` to chain
# themselves; under inline that would execute immediately and recurse
# until the stack overflows. See ADR 0002.
Sidekiq.testing!(:fake)

RSpec.configure do |config|
  config.before(:each) do
    Sidekiq::Job.clear_all
  end
end
