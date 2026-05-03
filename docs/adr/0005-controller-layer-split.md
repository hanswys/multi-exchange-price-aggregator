# Split controller bases: `ActionController::API` for `/price/*`, `ApplicationController` for the dashboard

**Status**: accepted (2026-05-03)

## Context

PR #8 introduces `Api::V1::PricesController` for `GET /price/:pair`. The repo
is a full Rails app (not `--api`) because the dashboard at `/` renders ERB
and uses Hotwire — so `ApplicationController < ActionController::Base`
exists already, with `allow_browser versions: :modern`.

`allow_browser :modern` rejects clients whose User-Agent doesn't claim
support for modern browser features. `curl` (no UA) is rejected, which
breaks the PR #8 acceptance criterion: *"`curl localhost:3000/price/BTC-USD`
returns the structured consensus."* Programmatic JSON consumers hit the
same wall.

The original design doc said `Api::V1::BaseController` should
`protect_from_forgery with: :null_session`, which is a Base-only API.
That was muscle memory from someone who hadn't decided between
`ActionController::API` and `ActionController::Base`.

## Decision

`Api::V1::BaseController < ActionController::API`. The dashboard's
controllers stay on `ApplicationController < ActionController::Base`.

`ActionController::API` has no CSRF middleware in the first place, so
`protect_from_forgery with: :null_session` is dropped — it would be a
no-op against an empty middleware stack. CORS is enforced separately
via `rack-cors` middleware regardless of the controller superclass.

## Considered Options

- **`Api::V1::BaseController < ApplicationController` + `skip_before_action :allow_browser_versions`.**
  Honors the design doc literally but layers two negations on an
  inheritance chain that exists for the HTML side.
- **Move `allow_browser` off `ApplicationController` onto a new
  `WebController` superclass.** Cleaner long-term but more diff churn for
  PR #8 and no immediate payoff — there's only one HTML controller today.

## Consequences

- The HTML side and the JSON side have different middleware stacks — by
  design. A reviewer reading both should not be surprised that
  `Api::V1::BaseController` doesn't inherit `protect_from_forgery`.
- If a future endpoint needs to render HTML *and* be CORS-allowed, that's
  a new decision — don't reflexively put it under `Api::V1::`.
