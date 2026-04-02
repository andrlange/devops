package cool.cfapps.kappman.service

import cool.cfapps.kappman.audit.AuditService
import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.servlet.mvc.support.RedirectAttributes

@Controller
class ServiceController(
    private val cfApiService: CfApiService,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService
) {

    @GetMapping("/services")
    fun listServices(model: Model): String {
        model.addAttribute("activePage", "services")
        model.addAttribute("pageTitle", "Services")

        val orgs = cfApiService.listOrgs()
        val orgsByGuid = orgs.associateBy { it.guid }
        val spaces = cfApiService.listSpaces()
        val spacesByGuid = spaces.associateBy { it.guid }
        val apps = cfApiService.listApps()
        val appsByGuid = apps.associateBy { it.guid }
        val services = cfApiService.listServiceInstances()
        val bindings = cfApiService.listBindings()
        val plans = cfApiService.listPlans()
        val plansByGuid = plans.associateBy { it.guid }
        val offerings = cfApiService.listOfferings()
        val offeringsByGuid = offerings.associateBy { it.guid }
        val orgUserCounts = userService.countUsersByOrgGuid()
        val spaceUserCounts = userService.countUsersBySpaceGuid()

        // Group bindings by service instance GUID
        val bindingsByService = bindings.groupBy { binding ->
            (binding.relationships?.get("service_instance") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
        }

        val serviceEntries = services.map { svc ->
            val spaceGuid = (svc.relationships?.get("space") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            val space = spacesByGuid[spaceGuid]
            val orgGuid = space?.let {
                (it.relationships?.get("organization") as? Map<*, *>)
                    ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
            } ?: ""
            val orgName = orgsByGuid[orgGuid]?.name ?: "-"
            val spaceName = space?.name ?: "-"

            // Resolve bound apps
            val svcBindings = bindingsByService[svc.guid] ?: emptyList()
            val boundApps = svcBindings.mapNotNull { binding ->
                val appGuid = (binding.relationships?.get("app") as? Map<*, *>)
                    ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String }
                appGuid?.let { appsByGuid[it]?.name }
            }

            // Resolve plan and offering
            val planGuid = (svc.relationships?.get("service_plan") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            val plan = plansByGuid[planGuid]
            val offeringGuid = plan?.let {
                (it.relationships?.get("service_offering") as? Map<*, *>)
                    ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
            } ?: ""
            val offering = offeringsByGuid[offeringGuid]

            mapOf(
                "service" to svc,
                "orgName" to orgName,
                "orgGuid" to orgGuid,
                "spaceName" to spaceName,
                "spaceGuid" to spaceGuid,
                "namespace" to if (spaceGuid.isNotEmpty()) "cf-space-$spaceGuid" else "-",
                "boundApps" to boundApps,
                "bindingCount" to svcBindings.size,
                "orgUserCount" to orgUserCounts.getValue(orgGuid),
                "spaceUserCount" to spaceUserCounts.getValue(spaceGuid),
                "planName" to (plan?.name ?: "-"),
                "offeringName" to (offering?.name ?: "-")
            )
        }

        // Group by Org -> Space
        data class SpaceGroup(val spaceName: String, val spaceGuid: String, val userCount: Int, val services: List<Map<String, Any?>>)
        data class OrgGroup(val orgName: String, val orgGuid: String, val userCount: Int, val spaceGroups: List<SpaceGroup>)

        val grouped = serviceEntries
            .groupBy { it["orgGuid"] as String }
            .map { (orgGuid, entries) ->
                val spaceGroups = entries
                    .groupBy { it["spaceGuid"] as String }
                    .map { (sg, spaceEntries) ->
                        SpaceGroup(spaceEntries.first()["spaceName"] as String, sg, spaceUserCounts.getValue(sg), spaceEntries)
                    }
                    .sortedBy { it.spaceName }
                OrgGroup(entries.first()["orgName"] as String, orgGuid, orgUserCounts.getValue(orgGuid), spaceGroups)
            }
            .sortedBy { it.orgName }

        model.addAttribute("orgGroups", grouped)
        return "service/list"
    }

    @PostMapping("/services")
    fun createService(@RequestParam name: String, @RequestParam spaceGuid: String, @RequestParam planGuid: String, redirectAttributes: RedirectAttributes): String {
        val svc = cfApiService.createServiceInstance(name, spaceGuid, planGuid)
        if (svc != null) {
            auditService.log("CREATE", "service_instance", svc.guid, "Created service: $name")
            redirectAttributes.addFlashAttribute("success", "Service '$name' created")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create service")
        }
        return "redirect:/services"
    }

    @PostMapping("/services/{guid}/delete")
    fun deleteService(@PathVariable guid: String, redirectAttributes: RedirectAttributes): String {
        if (cfApiService.deleteServiceInstance(guid)) {
            auditService.log("DELETE", "service_instance", guid)
            redirectAttributes.addFlashAttribute("success", "Service deleted")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to delete service")
        }
        return "redirect:/services"
    }

    @PostMapping("/services/{guid}/bindings")
    fun createBinding(@PathVariable guid: String, @RequestParam appGuid: String, redirectAttributes: RedirectAttributes): String {
        val binding = cfApiService.createBinding(appGuid, guid)
        if (binding != null) {
            auditService.log("CREATE", "service_binding", binding.guid)
            redirectAttributes.addFlashAttribute("success", "Service bound to app")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create binding")
        }
        return "redirect:/services"
    }

    @PostMapping("/bindings/{guid}/delete")
    fun deleteBinding(@PathVariable guid: String, redirectAttributes: RedirectAttributes): String {
        if (cfApiService.deleteBinding(guid)) {
            auditService.log("DELETE", "service_binding", guid)
            redirectAttributes.addFlashAttribute("success", "Binding deleted")
        }
        return "redirect:/services"
    }
}
