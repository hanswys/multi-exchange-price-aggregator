import { Controller } from "@hotwired/stimulus"

// Expands/collapses the per-row `detail` text in the rejection log. The
// detail span is rendered with the `hidden` attribute by the server.
export default class extends Controller {
  static targets = ["detail"]

  toggle(event) {
    event?.preventDefault()
    if (!this.hasDetailTarget) return

    const expanded = !this.detailTarget.hidden
    this.detailTarget.hidden = expanded
    const button = event?.currentTarget
    if (button) {
      button.setAttribute("aria-expanded", expanded ? "false" : "true")
      button.textContent = expanded ? "+" : "−"
    }
  }
}
