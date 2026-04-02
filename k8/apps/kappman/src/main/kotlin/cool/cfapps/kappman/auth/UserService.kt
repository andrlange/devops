package cool.cfapps.kappman.auth

import org.springframework.security.crypto.password.PasswordEncoder
import org.springframework.stereotype.Service
import org.springframework.transaction.annotation.Transactional
import java.time.LocalDateTime

@Service
class UserService(
    private val userRepository: UserRepository,
    private val passwordEncoder: PasswordEncoder
) {

    fun findAll(): List<User> = userRepository.findAll()

    @Transactional(readOnly = true)
    fun findAllWithAssignments(): List<Map<String, Any>> {
        return userRepository.findAll().map { user ->
            mapOf(
                "user" to user,
                "orgGuids" to user.orgAssignments.map { it.orgGuid }.toList(),
                "spaceGuids" to user.spaceAssignments.map { it.spaceGuid }.toList()
            )
        }
    }

    fun findById(id: Long): User? = userRepository.findById(id).orElse(null)

    @Transactional(readOnly = true)
    fun getAssignedOrgGuids(userId: Long): java.util.HashSet<String> {
        val user = userRepository.findById(userId).orElse(null) ?: return java.util.HashSet()
        return java.util.HashSet(user.orgAssignments.map { it.orgGuid })
    }

    @Transactional(readOnly = true)
    fun getAssignedSpaceGuids(userId: Long): java.util.HashSet<String> {
        val user = userRepository.findById(userId).orElse(null) ?: return java.util.HashSet()
        return java.util.HashSet(user.spaceAssignments.map { it.spaceGuid })
    }

    fun findByUsername(username: String): User? = userRepository.findByUsername(username)

    @Transactional(readOnly = true)
    fun countUsersByOrgGuid(): Map<String, Int> {
        val users = userRepository.findAll()
        val adminCount = users.count { it.role == UserRole.ADMIN }
        val orgCounts = mutableMapOf<String, Int>()
        users.filter { it.role != UserRole.ADMIN }.forEach { user ->
            user.orgAssignments.forEach { a -> orgCounts[a.orgGuid] = (orgCounts[a.orgGuid] ?: 0) + 1 }
        }
        // Admins have access to all orgs — add them to every org count
        return orgCounts.mapValues { it.value + adminCount }.withDefault { adminCount }
    }

    @Transactional(readOnly = true)
    fun countUsersBySpaceGuid(): Map<String, Int> {
        val users = userRepository.findAll()
        val adminCount = users.count { it.role == UserRole.ADMIN }
        val spaceCounts = mutableMapOf<String, Int>()
        users.filter { it.role != UserRole.ADMIN }.forEach { user ->
            user.spaceAssignments.forEach { a -> spaceCounts[a.spaceGuid] = (spaceCounts[a.spaceGuid] ?: 0) + 1 }
        }
        return spaceCounts.mapValues { it.value + adminCount }.withDefault { adminCount }
    }

    @Transactional
    fun createUser(username: String, password: String, displayName: String, email: String?, role: UserRole): User {
        val user = User(
            username = username,
            passwordHash = passwordEncoder.encode(password) ?: "",
            displayName = displayName,
            email = email,
            role = role
        )
        return userRepository.save(user)
    }

    @Transactional
    fun updateUser(id: Long, displayName: String, email: String?, role: UserRole, enabled: Boolean, password: String?): User? {
        val user = userRepository.findById(id).orElse(null) ?: return null
        user.displayName = displayName
        user.email = email ?: ""
        user.role = role
        user.enabled = enabled
        user.updatedAt = LocalDateTime.now()
        if (!password.isNullOrBlank()) {
            user.passwordHash = passwordEncoder.encode(password) ?: ""
        }
        return userRepository.save(user)
    }

    @Transactional
    fun deleteUser(id: Long): Boolean {
        if (!userRepository.existsById(id)) return false
        userRepository.deleteById(id)
        return true
    }

    @Transactional
    fun resetPassword(id: Long, newPassword: String): Boolean {
        val user = userRepository.findById(id).orElse(null) ?: return false
        user.passwordHash = passwordEncoder.encode(newPassword) ?: ""
        user.updatedAt = LocalDateTime.now()
        userRepository.save(user)
        return true
    }

    @Transactional
    fun addOrgAssignment(userId: Long, orgGuid: String): Boolean {
        val user = userRepository.findById(userId).orElse(null) ?: return false
        if (user.orgAssignments.any { it.orgGuid == orgGuid }) return false
        val assignment = UserOrgAssignment(user = user, orgGuid = orgGuid)
        user.orgAssignments.add(assignment)
        userRepository.save(user)
        return true
    }

    @Transactional
    fun removeOrgAssignment(userId: Long, orgGuid: String): Boolean {
        val user = userRepository.findById(userId).orElse(null) ?: return false
        user.orgAssignments.removeIf { it.orgGuid == orgGuid }
        userRepository.save(user)
        return true
    }

    @Transactional
    fun addSpaceAssignment(userId: Long, spaceGuid: String): Boolean {
        val user = userRepository.findById(userId).orElse(null) ?: return false
        if (user.spaceAssignments.any { it.spaceGuid == spaceGuid }) return false
        val assignment = UserSpaceAssignment(user = user, spaceGuid = spaceGuid)
        user.spaceAssignments.add(assignment)
        userRepository.save(user)
        return true
    }

    @Transactional
    fun removeSpaceAssignment(userId: Long, spaceGuid: String): Boolean {
        val user = userRepository.findById(userId).orElse(null) ?: return false
        user.spaceAssignments.removeIf { it.spaceGuid == spaceGuid }
        userRepository.save(user)
        return true
    }
}
