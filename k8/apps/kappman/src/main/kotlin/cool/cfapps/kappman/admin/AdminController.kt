package cool.cfapps.kappman.admin

import cool.cfapps.kappman.audit.AuditService
import cool.cfapps.kappman.auth.UserRole
import cool.cfapps.kappman.auth.UserService
import cool.cfapps.kappman.cfapi.CfApiService
import org.springframework.security.access.prepost.PreAuthorize
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.servlet.mvc.support.RedirectAttributes

@Controller
@RequestMapping("/admin")
@PreAuthorize("hasRole('ADMIN')")
class AdminController(
    private val userService: UserService,
    private val cfApiService: CfApiService,
    private val auditService: AuditService
) {

    @GetMapping("/users")
    fun listUsers(model: Model): String {
        model.addAttribute("activePage", "admin")
        model.addAttribute("pageTitle", "User Management")

        val orgs = cfApiService.listOrgs()
        val orgsByGuid = orgs.associateBy { it.guid }
        val spaces = cfApiService.listSpaces()
        val spacesByGuid = spaces.associateBy { it.guid }

        val usersWithAccess = userService.findAllWithAssignments().map { entry ->
            val orgGuids = entry["orgGuids"] as List<*>
            val spaceGuids = entry["spaceGuids"] as List<*>
            entry + mapOf(
                "orgNames" to orgGuids.mapNotNull { orgsByGuid[it as? String]?.name },
                "spaceNames" to spaceGuids.mapNotNull { guid ->
                    val space = spacesByGuid[guid as? String]
                    space?.name
                }
            )
        }

        model.addAttribute("users", usersWithAccess)
        return "admin/users"
    }

    @GetMapping("/users/new")
    fun newUserForm(model: Model): String {
        model.addAttribute("activePage", "admin")
        model.addAttribute("pageTitle", "Create User")
        model.addAttribute("roles", UserRole.entries)
        model.addAttribute("isNew", true)
        return "admin/user-form"
    }

    @PostMapping("/users")
    fun createUser(
        @RequestParam username: String,
        @RequestParam password: String,
        @RequestParam displayName: String,
        @RequestParam(required = false) email: String?,
        @RequestParam role: UserRole,
        redirectAttributes: RedirectAttributes
    ): String {
        try {
            userService.createUser(username, password, displayName, email, role)
            auditService.log("CREATE", "user", null, "Created user: $username")
            redirectAttributes.addFlashAttribute("success", "User '$username' created")
        } catch (e: Exception) {
            redirectAttributes.addFlashAttribute("error", "Failed to create user: ${e.message}")
        }
        return "redirect:/admin/users"
    }

    @GetMapping("/users/{id}/edit")
    fun editUserForm(@PathVariable id: Long, model: Model): String {
        model.addAttribute("activePage", "admin")
        model.addAttribute("pageTitle", "Edit User")
        model.addAttribute("user", userService.findById(id))
        model.addAttribute("roles", UserRole.entries)
        model.addAttribute("isNew", false)
        return "admin/user-form"
    }

    @PostMapping("/users/{id}")
    fun updateUser(
        @PathVariable id: Long,
        @RequestParam displayName: String,
        @RequestParam(required = false) email: String?,
        @RequestParam role: UserRole,
        @RequestParam(defaultValue = "true") enabled: Boolean,
        @RequestParam(required = false) password: String?,
        redirectAttributes: RedirectAttributes
    ): String {
        userService.updateUser(id, displayName, email, role, enabled, password)
        auditService.log("UPDATE", "user", id.toString())
        redirectAttributes.addFlashAttribute("success", "User updated")
        return "redirect:/admin/users"
    }

    @PostMapping("/users/{id}/delete")
    fun deleteUser(@PathVariable id: Long, redirectAttributes: RedirectAttributes): String {
        val currentUsername = SecurityContextHolder.getContext().authentication?.name
        val user = userService.findById(id)
        if (user?.username == currentUsername) {
            redirectAttributes.addFlashAttribute("error", "Cannot delete your own account")
            return "redirect:/admin/users"
        }
        if (userService.deleteUser(id)) {
            auditService.log("DELETE", "user", id.toString())
            redirectAttributes.addFlashAttribute("success", "User deleted")
        }
        return "redirect:/admin/users"
    }

    @GetMapping("/users/{id}/assignments")
    fun userAssignments(@PathVariable id: Long, model: Model): String {
        model.addAttribute("activePage", "admin")
        model.addAttribute("pageTitle", "User Assignments")
        val user = userService.findById(id)
        model.addAttribute("user", user)

        val allOrgs = cfApiService.listOrgs()
        val allSpaces = cfApiService.listSpaces()
        val orgsByGuid = allOrgs.associateBy { it.guid }

        // Enrich spaces with org name
        val spacesWithOrg = allSpaces.map { space ->
            val orgGuid = (space.relationships?.get("organization") as? Map<*, *>)
                ?.let { (it["data"] as? Map<*, *>)?.get("guid") as? String } ?: ""
            mapOf("space" to space, "orgName" to (orgsByGuid[orgGuid]?.name ?: "-"), "orgGuid" to orgGuid)
        }.sortedBy { (it["orgName"] as String) + (it["space"] as cool.cfapps.kappman.cfapi.model.CfSpace).name }

        model.addAttribute("allOrgs", allOrgs)
        model.addAttribute("spacesWithOrg", spacesWithOrg)
        model.addAttribute("assignedOrgGuids", userService.getAssignedOrgGuids(id))
        model.addAttribute("assignedSpaceGuids", userService.getAssignedSpaceGuids(id))
        return "admin/user-assignments"
    }

    @PostMapping("/users/{id}/assignments/orgs")
    fun addOrgAssignment(@PathVariable id: Long, @RequestParam orgGuid: String, redirectAttributes: RedirectAttributes): String {
        userService.addOrgAssignment(id, orgGuid)
        // Also assign all spaces in this org
        val spaces = cfApiService.listSpaces(orgGuid)
        spaces.forEach { space -> userService.addSpaceAssignment(id, space.guid) }
        return "redirect:/admin/users/$id/assignments"
    }

    @PostMapping("/users/{id}/assignments/orgs/{orgGuid}/delete")
    fun removeOrgAssignment(@PathVariable id: Long, @PathVariable orgGuid: String): String {
        userService.removeOrgAssignment(id, orgGuid)
        // Also remove all spaces in this org
        val spaces = cfApiService.listSpaces(orgGuid)
        spaces.forEach { space -> userService.removeSpaceAssignment(id, space.guid) }
        return "redirect:/admin/users/$id/assignments"
    }

    @PostMapping("/users/{id}/assignments/spaces")
    fun addSpaceAssignment(@PathVariable id: Long, @RequestParam spaceGuid: String, redirectAttributes: RedirectAttributes): String {
        userService.addSpaceAssignment(id, spaceGuid)
        // Also assign the parent org
        val allSpaces = cfApiService.listSpaces()
        val space = allSpaces.find { it.guid == spaceGuid }
        val orgGuid = space?.let {
            (it.relationships?.get("organization") as? Map<*, *>)
                ?.let { rel -> (rel["data"] as? Map<*, *>)?.get("guid") as? String }
        }
        if (orgGuid != null) userService.addOrgAssignment(id, orgGuid)
        return "redirect:/admin/users/$id/assignments"
    }

    @PostMapping("/users/{id}/assignments/spaces/{spaceGuid}/delete")
    fun removeSpaceAssignment(@PathVariable id: Long, @PathVariable spaceGuid: String): String {
        userService.removeSpaceAssignment(id, spaceGuid)
        return "redirect:/admin/users/$id/assignments"
    }

    @PostMapping("/users/{id}/reset-password")
    fun resetPassword(@PathVariable id: Long, @RequestParam newPassword: String, redirectAttributes: RedirectAttributes): String {
        userService.resetPassword(id, newPassword)
        auditService.log("RESET_PASSWORD", "user", id.toString())
        redirectAttributes.addFlashAttribute("success", "Password reset")
        return "redirect:/admin/users"
    }
}
