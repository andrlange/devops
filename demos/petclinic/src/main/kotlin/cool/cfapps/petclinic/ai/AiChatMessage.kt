package cool.cfapps.petclinic.ai

import cool.cfapps.petclinic.pet.Pet
import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "ai_chat_messages")
class AiChatMessage(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long = 0,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "pet_id")
    var pet: Pet = Pet(),

    @Column(name = "session_id")
    var sessionId: String = "",

    @Column(name = "role")
    var role: String = "",

    @Column(name = "content", columnDefinition = "TEXT")
    var content: String = "",

    @Column(name = "knowledge_refs", columnDefinition = "TEXT")
    var knowledgeRefs: String? = null,

    @Column(name = "created_at")
    var createdAt: LocalDateTime = LocalDateTime.now()
)
