# TODOS

Captured by /plan-eng-review on 2026-04-26.

---

## README: defend the Sidekiq choice against Solid Queue

**What:** Add a paragraph to the README's "What I didn't build and why"
section explaining why this project uses Sidekiq when Rails 7.1+ ships Solid
Queue as the default background runner.

**Why:** A 2026 reviewer reading this repo will ask "why not the new default?"
within 10 seconds of seeing `gem "sidekiq"` in the Gemfile. Pre-empting that
question in the README converts the obvious-friction-point into a
judgment-signal.

**Pros:**
- Turns a "why didn't you" gotcha into a "good, they thought about it"
- Demonstrates awareness of current Rails ecosystem
- Free signal — pure documentation, no code change

**Cons:**
- ~15 min of README writing once the project ships
- The defense has to be honest (not "I just know Sidekiq better")

**Suggested defense angle:**
- Sub-2s self-rescheduling jobs are well-trodden with Sidekiq's
  `perform_in`. Solid Queue's recurring-task primitives are coarser-grained.
- Real production experience operating Sidekiq at PostCo. The README leans
  into "this is the stack I'm senior in" framing already.
- Honest acknowledgment that for a fresh greenfield app with no prior
  ecosystem ties, Solid Queue would be the right default.

**Context:** Pure documentation, no code change. Lands in README v1
or as a v1.1 docs commit.

**Depends on:** v1 shipped first.
