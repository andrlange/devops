package cool.cfapps.kappman.dashboard

import cool.cfapps.kappman.audit.AuditService
import cool.cfapps.kappman.auth.UserRepository
import cool.cfapps.kappman.auth.UserRole
import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.GetMapping

@Controller
class DashboardController(
    private val cfApiService: CfApiService,
    private val auditService: AuditService,
    private val userRepository: UserRepository,
    private val userService: cool.cfapps.kappman.auth.UserService
) {

    @GetMapping("/")
    fun dashboard(model: Model): String {
        model.addAttribute("activePage", "dashboard")
        model.addAttribute("pageTitle", "Dashboard")
        model.addAttribute("cfConfigured", cfApiService.isConfigured())

        if (cfApiService.isConfigured()) {
            val currentUser = getCurrentUser()
            val allOrgs = cfApiService.listOrgs()
            val allSpaces = cfApiService.listSpaces()
            val allApps = cfApiService.listApps()
            val allServices = cfApiService.listServiceInstances()

            // Top 10 lists
            val topOrgs = allOrgs.take(10).map { mapOf("name" to it.name, "guid" to it.guid) }
            val topSpaces = allSpaces.take(10).map { space ->
                val orgGuid = (space.relationships?.get("organization") as? Map<*, *>)
                    ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
                val orgName = allOrgs.find { it.guid == orgGuid }?.name ?: "-"
                mapOf("name" to space.name, "guid" to space.guid, "orgName" to orgName)
            }
            val topApps = allApps.take(10).map { mapOf("name" to it.name, "guid" to it.guid, "state" to it.state) }
            val topServices = allServices.take(10).map { mapOf("name" to it.name, "guid" to it.guid, "type" to it.type) }

            model.addAttribute("topOrgs", topOrgs)
            model.addAttribute("topSpaces", topSpaces)
            model.addAttribute("topApps", topApps)
            model.addAttribute("topServices", topServices)

            if (currentUser?.role == UserRole.ADMIN) {
                model.addAttribute("orgCount", allOrgs.size)
                model.addAttribute("spaceCount", allSpaces.size)
                model.addAttribute("appCount", allApps.size)
                model.addAttribute("serviceCount", allServices.size)
            } else {
                val assignedOrgGuids = currentUser?.let { userService.getAssignedOrgGuids(it.id) } ?: java.util.HashSet()
                val assignedSpaceGuids = currentUser?.let { userService.getAssignedSpaceGuids(it.id) } ?: java.util.HashSet()
                model.addAttribute("orgCount", allOrgs.count { it.guid in assignedOrgGuids })
                model.addAttribute("spaceCount", allSpaces.count { it.guid in assignedSpaceGuids })
                model.addAttribute("appCount", allApps.size)
                model.addAttribute("serviceCount", allServices.size)
            }

            // Resource consumption: aggregate process data across all apps
            var totalMemoryMb = 0
            var totalDiskMb = 0
            var totalInstances = 0
            var runningApps = 0
            var stoppedApps = 0

            allApps.forEach { app ->
                if (app.state == "STARTED") runningApps++ else stoppedApps++
                val processes = cfApiService.getAppProcesses(app.guid)
                processes.filter { it.type == "web" }.forEach { proc ->
                    totalInstances += proc.instances
                    totalMemoryMb += proc.memoryInMb * proc.instances
                    totalDiskMb += proc.diskInMb * proc.instances
                }
            }

            model.addAttribute("totalMemoryMb", totalMemoryMb)
            model.addAttribute("totalMemoryGb", String.format("%.1f", totalMemoryMb / 1024.0))
            model.addAttribute("totalDiskMb", totalDiskMb)
            model.addAttribute("totalDiskGb", String.format("%.1f", totalDiskMb / 1024.0))
            model.addAttribute("totalInstances", totalInstances)
            model.addAttribute("runningApps", runningApps)
            model.addAttribute("stoppedApps", stoppedApps)

            val info = cfApiService.getInfo()
            model.addAttribute("cfInfo", info)
            model.addAttribute("cfApiHealthy", info != null)
        } else {
            model.addAttribute("orgCount", 0)
            model.addAttribute("spaceCount", 0)
            model.addAttribute("appCount", 0)
            model.addAttribute("serviceCount", 0)
            model.addAttribute("cfApiHealthy", false)
            model.addAttribute("topOrgs", emptyList<Any>())
            model.addAttribute("topSpaces", emptyList<Any>())
            model.addAttribute("topApps", emptyList<Any>())
            model.addAttribute("topServices", emptyList<Any>())
            model.addAttribute("totalMemoryMb", 0)
            model.addAttribute("totalMemoryGb", "0.0")
            model.addAttribute("totalDiskMb", 0)
            model.addAttribute("totalDiskGb", "0.0")
            model.addAttribute("totalInstances", 0)
            model.addAttribute("runningApps", 0)
            model.addAttribute("stoppedApps", 0)
        }

        model.addAttribute("recentActivity", auditService.recentEntries())
        return "dashboard/index"
    }

    private fun getCurrentUser(): cool.cfapps.kappman.auth.User? {
        val username = SecurityContextHolder.getContext().authentication?.name ?: return null
        return userRepository.findByUsername(username)
    }
}
