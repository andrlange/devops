package cool.cfapps.kappman.status

import cool.cfapps.kappman.cfapi.CfApiService
import jakarta.servlet.http.HttpServletRequest
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping

@Controller
class StatusController(
    private val cfApiService: CfApiService
) {

    @GetMapping("/status")
    fun status(model: Model): String {
        model.addAttribute("activePage", "status")
        model.addAttribute("pageTitle", "Korifi Status")
        addHealthAttributes(model)
        return "status/index"
    }

    @GetMapping("/status/health")
    fun healthFragment(model: Model): String {
        addHealthAttributes(model)
        return "status/fragments/health"
    }

    private fun addHealthAttributes(model: Model) {
        val info = cfApiService.getInfo()
        model.addAttribute("cfInfo", info)
        model.addAttribute("cfApiHealthy", info != null)
        model.addAttribute("cfConfigured", cfApiService.isConfigured())

        // Check buildpacks as a proxy for kpack health
        val buildpacks = if (info != null) cfApiService.listBuildpacks() else emptyList()
        model.addAttribute("kpackHealthy", buildpacks.isNotEmpty())
        model.addAttribute("buildpackCount", buildpacks.size)

        // Check service offerings as a proxy for broker health
        val offerings = if (info != null) cfApiService.listOfferings() else emptyList()
        model.addAttribute("brokerHealthy", offerings.isNotEmpty())
        model.addAttribute("offeringCount", offerings.size)
    }
}
