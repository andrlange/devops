package cool.cfapps.kappman.space

import cool.cfapps.kappman.audit.AuditService
import cool.cfapps.kappman.auth.UserRepository
import cool.cfapps.kappman.auth.UserRole
import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.security.access.prepost.PreAuthorize
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.servlet.mvc.support.RedirectAttributes

@Controller
class SpaceController(
    private val cfApiService: CfApiService,
    private val userRepository: UserRepository,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService
) {

    @GetMapping("/spaces")
    fun listAllSpaces(model: Model): String {
        model.addAttribute("activePage", "spaces")
        model.addAttribute("pageTitle", "Spaces")

        val currentUser = getCurrentUser()
        val spaces = cfApiService.listSpaces()
        val filteredSpaces = if (currentUser?.role == UserRole.ADMIN) {
            spaces
        } else {
            val assignedGuids = currentUser?.let { userService.getAssignedSpaceGuids(it.id) } ?: java.util.HashSet()
            spaces.filter { it.guid in assignedGuids }
        }

        val orgs = cfApiService.listOrgs()
        val orgsByGuid = orgs.associateBy { it.guid }

        data class SpaceEntry(val space: cool.cfapps.kappman.cfapi.model.CfSpace, val orgName: String, val orgGuid: String, val userCount: Int)
        data class OrgGroup(val orgName: String, val orgGuid: String, val spaces: List<SpaceEntry>, val userCount: Int)

        val orgUserCounts = userService.countUsersByOrgGuid()
        val spaceUserCounts = userService.countUsersBySpaceGuid()

        val spaceEntries = filteredSpaces.map { space ->
            val orgGuid = (space.relationships?.get("organization") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            val orgName = orgsByGuid[orgGuid]?.name ?: "-"
            SpaceEntry(space, orgName, orgGuid, spaceUserCounts.getValue(space.guid))
        }

        val orgGroups = spaceEntries
            .groupBy { it.orgGuid }
            .map { (orgGuid, entries) -> OrgGroup(entries.first().orgName, orgGuid, entries.sortedBy { it.space.name }, orgUserCounts.getValue(orgGuid)) }
            .sortedBy { it.orgName }

        model.addAttribute("orgGroups", orgGroups)
        model.addAttribute("isAdmin", currentUser?.role == UserRole.ADMIN)
        return "space/list"
    }

    @GetMapping("/orgs/{orgGuid}/spaces/{spaceGuid}")
    fun spaceDetail(@PathVariable orgGuid: String, @PathVariable spaceGuid: String, model: Model): String {
        model.addAttribute("activePage", "spaces")
        val orgs = cfApiService.listOrgs()
        val org = orgs.find { it.guid == orgGuid }
        val spaces = cfApiService.listSpaces(orgGuid)
        val space = spaces.find { it.guid == spaceGuid }

        model.addAttribute("org", org)
        model.addAttribute("space", space)
        model.addAttribute("pageTitle", space?.name ?: "Space")
        model.addAttribute("apps", cfApiService.listApps(spaceGuid))
        model.addAttribute("services", cfApiService.listServiceInstances(spaceGuid))
        model.addAttribute("isAdmin", getCurrentUser()?.role == UserRole.ADMIN)
        return "space/detail"
    }

    @PostMapping("/orgs/{orgGuid}/spaces")
    @PreAuthorize("hasRole('ADMIN')")
    fun createSpace(@PathVariable orgGuid: String, @RequestParam name: String, redirectAttributes: RedirectAttributes): String {
        val space = cfApiService.createSpace(name, orgGuid)
        if (space != null) {
            auditService.log("CREATE", "space", space.guid, "Created space: $name")
            redirectAttributes.addFlashAttribute("success", "Space '$name' created")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create space")
        }
        return "redirect:/orgs/$orgGuid"
    }

    @PostMapping("/orgs/{orgGuid}/spaces/{spaceGuid}/delete")
    @PreAuthorize("hasRole('ADMIN')")
    fun deleteSpace(@PathVariable orgGuid: String, @PathVariable spaceGuid: String, redirectAttributes: RedirectAttributes): String {
        if (cfApiService.deleteSpace(spaceGuid)) {
            auditService.log("DELETE", "space", spaceGuid)
            redirectAttributes.addFlashAttribute("success", "Space deleted")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to delete space")
        }
        return "redirect:/orgs/$orgGuid"
    }

    private fun getCurrentUser(): cool.cfapps.kappman.auth.User? {
        val username = SecurityContextHolder.getContext().authentication?.name ?: return null
        return userRepository.findByUsername(username)
    }
}
