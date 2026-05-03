require "rails_helper"

# This initializer fires `PollerSupervisorJob.perform_async` only when
# Sidekiq is running as a server (i.e. inside the worker process). In the
# test suite, web process, and rails console, it must be a no-op —
# otherwise every `bin/rails console` session would trigger the polling
# pipeline against live exchanges.
RSpec.describe Aggregator::Poller do
  before { PollerSupervisorJob.clear }

  describe ".kick!" do
    it "is a no-op when Sidekiq.server? is false (the test default)" do
      allow(Sidekiq).to receive(:server?).and_return(false)

      expect { described_class.kick! }.not_to change(PollerSupervisorJob.jobs, :size)
    end

    it "enqueues PollerSupervisorJob exactly once when Sidekiq.server? is true" do
      allow(Sidekiq).to receive(:server?).and_return(true)

      expect { described_class.kick! }
        .to change(PollerSupervisorJob.jobs, :size).by(1)
    end
  end
end
