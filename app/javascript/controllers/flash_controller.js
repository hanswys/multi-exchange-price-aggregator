import { Controller } from "@hotwired/stimulus"

// Attaches to #consensus_hero (NOT replaced on broadcast). When a
// turbo-stream targeting our element arrives, capture the previous
// price text, let Turbo render, then compare and tint the new
// .price element with .flash-up or .flash-down for ~200ms. Also
// updates document.title with the new price so a backgrounded tab
// doubles as a ticker.
//
// See docs/adr/0007-broadcast-chain-design.md for why the controller
// lives on the non-replaced parent: broadcasts use `update_to`, so
// the children swap but the controller's element persists across
// updates.
export default class extends Controller {
  static FLASH_MS = 200

  connect() {
    this.previousPrice = this.currentPriceText()
    this.applyTitle(this.previousPrice)
    this.boundOnRender = this.onBeforeStreamRender.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundOnRender)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.boundOnRender)
  }

  onBeforeStreamRender(event) {
    const stream = event.target
    if (!stream || stream.getAttribute("target") !== this.element.id) return

    if (document.body.classList.contains("paused")) {
      event.preventDefault()
      return
    }

    const original = event.detail.render
    event.detail.render = async (streamElement) => {
      await original(streamElement)
      requestAnimationFrame(() => this.afterRender())
    }
  }

  afterRender() {
    const newPrice = this.currentPriceText()
    if (newPrice == null) return

    this.applyTitle(newPrice)

    const oldNum = this.parsePrice(this.previousPrice)
    const newNum = this.parsePrice(newPrice)
    if (oldNum != null && newNum != null && oldNum !== newNum) {
      const cls = newNum > oldNum ? "flash-up" : "flash-down"
      const target = this.element.querySelector('[data-flash-target="price"]')
      if (target) {
        target.classList.remove("flash-up", "flash-down")
        // force reflow so the same class can flash again on rapid changes
        void target.offsetWidth
        target.classList.add(cls)
        setTimeout(() => target.classList.remove(cls), this.constructor.FLASH_MS)
      }
    }
    this.previousPrice = newPrice
  }

  currentPriceText() {
    const el = this.element.querySelector('[data-flash-target="price"]')
    return el ? el.textContent.trim() : null
  }

  parsePrice(text) {
    if (!text) return null
    const cleaned = text.replace(/,/g, "")
    const n = parseFloat(cleaned)
    return Number.isFinite(n) ? n : null
  }

  applyTitle(priceText) {
    const n = this.parsePrice(priceText)
    if (n == null) {
      document.title = "BTC-USD — Aggregator"
    } else {
      document.title = `BTC-USD · ${priceText} — Aggregator`
    }
  }
}
