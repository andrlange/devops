package cool.cfapps.kappman.app

import cool.cfapps.kappman.audit.AuditService
import cool.cfapps.kappman.auth.UserRepository
import cool.cfapps.kappman.auth.UserRole
import cool.cfapps.kappman.cfapi.CfApiService
import jakarta.servlet.http.HttpServletRequest
import org.springframework.security.access.prepost.PreAuthorize
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.servlet.mvc.support.RedirectAttributes

@Controller
class AppController(
    private val cfApiService: CfApiService,
    private val userRepository: UserRepository,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService
) {

    @GetMapping("/apps")
    fun listApps(model: Model): String {
        model.addAttribute("activePage", "apps")
        model.addAttribute("pageTitle", "Applications")

        val orgs = cfApiService.listOrgs()
        val orgsByGuid = orgs.associateBy { it.guid }
        val spaces = cfApiService.listSpaces()
        val spacesByGuid = spaces.associateBy { it.guid }
        val apps = cfApiService.listApps()

        // Build grouped structure: Org -> Space -> Apps
        data class AppEntry(
            val app: cool.cfapps.kappman.cfapi.model.CfApp,
            val spaceName: String, val spaceGuid: String,
            val orgName: String, val orgGuid: String,
            val buildpack: String, val memoryMb: Int, val diskMb: Int,
            val routes: List<String>
        )
        data class SpaceGroup(val spaceName: String, val spaceGuid: String, val apps: List<AppEntry>, val userCount: Int)
        data class OrgGroup(val orgName: String, val orgGuid: String, val spaceGroups: List<SpaceGroup>, val userCount: Int)

        val appEntries = apps.map { app ->
            val spaceGuid = (app.relationships?.get("space") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            val space = spacesByGuid[spaceGuid]
            val orgGuid = space?.let {
                (it.relationships?.get("organization") as? Map<*, *>)
                    ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
            } ?: ""

            // Buildpack from lifecycle
            val buildpacks = (app.lifecycle?.data?.get("buildpacks") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
            val buildpack = buildpacks.firstOrNull()?.substringAfterLast("/") ?: "-"

            // Process info (mem, disk)
            val processes = cfApiService.getAppProcesses(app.guid)
            val webProcess = processes.find { it.type == "web" }

            // Routes
            val appRoutes = cfApiService.getAppRoutes(app.guid)
            val routeUrls = appRoutes.map { it.url }.filter { it.isNotBlank() }

            AppEntry(
                app, space?.name ?: "-", spaceGuid, orgsByGuid[orgGuid]?.name ?: "-", orgGuid,
                buildpack, webProcess?.memoryInMb ?: 0, webProcess?.diskInMb ?: 0, routeUrls
            )
        }

        val orgUserCounts = userService.countUsersByOrgGuid()
        val spaceUserCounts = userService.countUsersBySpaceGuid()

        val grouped = appEntries
            .groupBy { it.orgGuid }
            .map { (orgGuid, entries) ->
                val spaceGroups = entries
                    .groupBy { it.spaceGuid }
                    .map { (sg, spaceEntries) -> SpaceGroup(spaceEntries.first().spaceName, sg, spaceEntries, spaceUserCounts.getValue(sg)) }
                    .sortedBy { it.spaceName }
                OrgGroup(entries.first().orgName, orgGuid, spaceGroups, orgUserCounts.getValue(orgGuid))
            }
            .sortedBy { it.orgName }

        model.addAttribute("orgGroups", grouped)
        model.addAttribute("isAdmin", getCurrentUser()?.role == UserRole.ADMIN)
        return "app/list"
    }

    @GetMapping("/apps/{guid}")
    fun appDetail(@PathVariable guid: String, model: Model): String {
        model.addAttribute("activePage", "apps")
        val app = cfApiService.getApp(guid)
        model.addAttribute("app", app)
        model.addAttribute("pageTitle", app?.name ?: "Application")
        model.addAttribute("processes", cfApiService.getAppProcesses(guid))
        model.addAttribute("routes", cfApiService.getAppRoutes(guid))
        model.addAttribute("isAdmin", getCurrentUser()?.role == UserRole.ADMIN)

        // Resolve bound services with type and plan
        val bindings = cfApiService.listBindings(appGuid = guid)
        val serviceInstances = cfApiService.listServiceInstances()
        val svcByGuid = serviceInstances.associateBy { it.guid }
        val plans = cfApiService.listPlans()
        val plansByGuid = plans.associateBy { it.guid }
        val offerings = cfApiService.listOfferings()
        val offeringsByGuid = offerings.associateBy { it.guid }

        val enrichedBindings = bindings.map { binding ->
            val svcGuid = (binding.relationships?.get("service_instance") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            val svc = svcByGuid[svcGuid]
            val planGuid = svc?.let {
                (it.relationships?.get("service_plan") as? Map<*, *>)
                    ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
            } ?: ""
            val plan = plansByGuid[planGuid]
            val offeringGuid = plan?.let {
                (it.relationships?.get("service_offering") as? Map<*, *>)
                    ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
            } ?: ""
            val offering = offeringsByGuid[offeringGuid]
            mapOf(
                "binding" to binding,
                "serviceName" to (svc?.name ?: binding.name ?: binding.guid),
                "offeringName" to (offering?.name ?: "-"),
                "planName" to (plan?.name ?: "-")
            )
        }
        model.addAttribute("bindings", enrichedBindings)

        // Resolve org/space
        val spaceGuid = (app?.relationships?.get("space") as? Map<*, *>)
            ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
        val spaces = cfApiService.listSpaces()
        val space = spaces.find { it.guid == spaceGuid }
        val orgGuid = space?.let {
            (it.relationships?.get("organization") as? Map<*, *>)
                ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
        } ?: ""
        val orgs = cfApiService.listOrgs()
        val org = orgs.find { it.guid == orgGuid }
        model.addAttribute("orgName", org?.name ?: "-")
        model.addAttribute("orgGuid", orgGuid)
        model.addAttribute("spaceName", space?.name ?: "-")
        model.addAttribute("spaceGuid", spaceGuid)

        return "app/detail"
    }

    // HTMX endpoints
    @PostMapping("/apps/{guid}/start")
    fun startApp(@PathVariable guid: String, model: Model, request: HttpServletRequest): String {
        val app = cfApiService.startApp(guid)
        auditService.log("START", "application", guid, "Started app: ${app?.name}")
        if (isHtmxRequest(request)) {
            model.addAttribute("app", app ?: cfApiService.getApp(guid))
            return "app/fragments/status-badge"
        }
        return "redirect:/apps/$guid"
    }

    @PostMapping("/apps/{guid}/stop")
    fun stopApp(@PathVariable guid: String, model: Model, request: HttpServletRequest): String {
        val app = cfApiService.stopApp(guid)
        auditService.log("STOP", "application", guid, "Stopped app: ${app?.name}")
        if (isHtmxRequest(request)) {
            model.addAttribute("app", app ?: cfApiService.getApp(guid))
            return "app/fragments/status-badge"
        }
        return "redirect:/apps/$guid"
    }

    @PostMapping("/apps/{guid}/restart")
    fun restartApp(@PathVariable guid: String, model: Model, request: HttpServletRequest): String {
        val app = cfApiService.restartApp(guid)
        auditService.log("RESTART", "application", guid, "Restarted app: ${app?.name}")
        if (isHtmxRequest(request)) {
            model.addAttribute("app", app ?: cfApiService.getApp(guid))
            return "app/fragments/status-badge"
        }
        return "redirect:/apps/$guid"
    }

    @PostMapping("/apps/{guid}/scale")
    fun scaleApp(@PathVariable guid: String, @RequestParam instances: Int, model: Model, request: HttpServletRequest): String {
        val process = cfApiService.scaleApp(guid, instances = instances)
        auditService.log("SCALE", "application", guid, "Scaled to $instances instances")
        if (isHtmxRequest(request)) {
            model.addAttribute("processes", cfApiService.getAppProcesses(guid))
            return "app/fragments/instances"
        }
        return "redirect:/apps/$guid"
    }

    @GetMapping("/apps/{guid}/logs")
    fun appLogs(@PathVariable guid: String, model: Model): String {
        model.addAttribute("logs", cfApiService.getAppLogs(guid))
        return "app/fragments/logs"
    }

    @GetMapping("/apps/{guid}/env")
    fun appEnv(@PathVariable guid: String, model: Model): String {
        val env = cfApiService.getAppEnv(guid)
        val envVars = (env?.get("environment_variables") as? Map<*, *>) ?: emptyMap<String, Any>()
        model.addAttribute("envVars", envVars)
        model.addAttribute("appGuid", guid)
        return "app/fragments/env-vars"
    }

    @PostMapping("/apps/{guid}/env")
    fun setAppEnv(@PathVariable guid: String, @RequestParam key: String, @RequestParam value: String, model: Model): String {
        cfApiService.setAppEnv(guid, mapOf(key to value))
        auditService.log("SET_ENV", "application", guid, "Set env var: $key")
        val env = cfApiService.getAppEnv(guid)
        val envVars = (env?.get("environment_variables") as? Map<*, *>) ?: emptyMap<String, Any>()
        model.addAttribute("envVars", envVars)
        model.addAttribute("appGuid", guid)
        return "app/fragments/env-vars"
    }

    @PostMapping("/apps/{guid}/delete")
    @PreAuthorize("hasRole('ADMIN')")
    fun deleteApp(@PathVariable guid: String, redirectAttributes: RedirectAttributes): String {
        if (cfApiService.deleteApp(guid)) {
            auditService.log("DELETE", "application", guid)
            redirectAttributes.addFlashAttribute("success", "Application deleted")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to delete application")
        }
        return "redirect:/apps"
    }

    private fun isHtmxRequest(request: HttpServletRequest): Boolean =
        request.getHeader("HX-Request") != null

    private fun getCurrentUser(): cool.cfapps.kappman.auth.User? {
        val username = SecurityContextHolder.getContext().authentication?.name ?: return null
        return userRepository.findByUsername(username)
    }
}
