package cool.cfapps.kappman.audit

import org.springframework.data.jpa.repository.JpaRepository

interface AuditLogRepository : JpaRepository<AuditLog, Long> {
    fun findTop20ByOrderByCreatedAtDesc(): List<AuditLog>
}
