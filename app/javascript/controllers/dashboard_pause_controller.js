import { Controller } from "@hotwired/stimulus"

// Toggles the `paused` class on <body>. The Phase 5 broadcast subscriber
// will check that class before applying Turbo Stream replacements.
// Static phase: the toggle is a no-op visually but keeps the reviewer's
// keyboard path live.
export default class extends Controller {
  toggle(event) {
    event?.preventDefault()
    document.body.classList.toggle("paused")
    const button = this.element.querySelector("button[data-pause-button]")
    if (button) {
      const paused = document.body.classList.contains("paused")
      button.setAttribute("aria-pressed", paused ? "true" : "false")
      button.textContent = paused ? "Resume" : "Pause"
    }
  }
}
