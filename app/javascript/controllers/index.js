import { Application } from "@hotwired/stimulus"
import DashboardPauseController from "./dashboard_pause_controller"
import FlashController from "./flash_controller"
import RejectionDetailController from "./rejection_detail_controller"

const application = Application.start()
application.register("dashboard-pause", DashboardPauseController)
application.register("flash", FlashController)
application.register("rejection-detail", RejectionDetailController)

window.Stimulus = application
