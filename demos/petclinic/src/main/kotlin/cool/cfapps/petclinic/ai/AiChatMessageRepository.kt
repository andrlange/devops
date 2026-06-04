package cool.cfapps.petclinic.ai

import org.springframework.data.jpa.repository.JpaRepository
import org.springframework.stereotype.Repository

@Repository
interface AiChatMessageRepository : JpaRepository<AiChatMessage, Long> {
    fun findByPetIdOrderByCreatedAtAsc(petId: Long): List<AiChatMessage>
    fun findBySessionIdOrderByCreatedAtAsc(sessionId: String): List<AiChatMessage>
    fun findByPetIdAndSessionIdOrderByCreatedAtAsc(petId: Long, sessionId: String): List<AiChatMessage>
}
