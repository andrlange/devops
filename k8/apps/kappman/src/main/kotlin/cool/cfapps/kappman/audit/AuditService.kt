package cool.cfapps.kappman.audit

import cool.cfapps.kappman.auth.User
import cool.cfapps.kappman.auth.UserRepository
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Service

@Service
class AuditService(
    private val auditLogRepository: AuditLogRepository,
    private val userRepository: UserRepository
) {

    fun log(action: String, resourceType: String, resourceGuid: String? = null, details: String? = null) {
        val username = SecurityContextHolder.getContext().authentication?.name
        val user = username?.let { userRepository.findByUsername(it) }

        auditLogRepository.save(
            AuditLog(
                user = user,
                action = action,
                resourceType = resourceType,
                resourceGuid = resourceGuid,
                details = details
            )
        )
    }

    fun recentEntries(): List<AuditLog> = auditLogRepository.findTop20ByOrderByCreatedAtDesc()
}
