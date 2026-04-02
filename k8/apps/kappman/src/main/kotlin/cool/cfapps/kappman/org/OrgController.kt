package cool.cfapps.kappman.org

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
@RequestMapping("/orgs")
class OrgController(
    private val cfApiService: CfApiService,
    private val userRepository: UserRepository,
    private val auditService: AuditService,
    private val userService: cool.cfapps.kappman.auth.UserService
) {

    @GetMapping
    fun listOrgs(model: Model): String {
        model.addAttribute("activePage", "orgs")
        model.addAttribute("pageTitle", "Organizations")

        val orgs = cfApiService.listOrgs()
        val currentUser = getCurrentUser()

        val filteredOrgs = if (currentUser?.role == UserRole.ADMIN) {
            orgs
        } else {
            val assignedGuids = currentUser?.let { userService.getAssignedOrgGuids(it.id) } ?: java.util.HashSet()
            orgs.filter { it.guid in assignedGuids }
        }

        val orgUserCounts = userService.countUsersByOrgGuid()

        val orgWithSpaceCounts = filteredOrgs.map { org ->
            val spaceCount = cfApiService.listSpaces(org.guid).size
            mapOf("org" to org, "spaceCount" to spaceCount, "userCount" to orgUserCounts.getValue(org.guid))
        }

        model.addAttribute("orgs", orgWithSpaceCounts)
        model.addAttribute("isAdmin", currentUser?.role == UserRole.ADMIN)
        return "org/list"
    }

    @GetMapping("/{guid}")
    fun orgDetail(@PathVariable guid: String, model: Model): String {
        model.addAttribute("activePage", "orgs")
        val orgs = cfApiService.listOrgs()
        val org = orgs.find { it.guid == guid }
        model.addAttribute("org", org)
        model.addAttribute("pageTitle", org?.name ?: "Organization")
        model.addAttribute("spaces", cfApiService.listSpaces(guid))
        model.addAttribute("isAdmin", getCurrentUser()?.role == UserRole.ADMIN)
        return "org/detail"
    }

    @PostMapping
    @PreAuthorize("hasRole('ADMIN')")
    fun createOrg(@RequestParam name: String, redirectAttributes: RedirectAttributes): String {
        val org = cfApiService.createOrg(name)
        if (org != null) {
            auditService.log("CREATE", "organization", org.guid, "Created org: $name")
            redirectAttributes.addFlashAttribute("success", "Organization '$name' created")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to create organization")
        }
        return "redirect:/orgs"
    }

    @PostMapping("/{guid}/delete")
    @PreAuthorize("hasRole('ADMIN')")
    fun deleteOrg(@PathVariable guid: String, redirectAttributes: RedirectAttributes): String {
        if (cfApiService.deleteOrg(guid)) {
            auditService.log("DELETE", "organization", guid)
            redirectAttributes.addFlashAttribute("success", "Organization deleted")
        } else {
            redirectAttributes.addFlashAttribute("error", "Failed to delete organization")
        }
        return "redirect:/orgs"
    }

    private fun getCurrentUser(): cool.cfapps.kappman.auth.User? {
        val username = SecurityContextHolder.getContext().authentication?.name ?: return null
        return userRepository.findByUsername(username)
    }
}
