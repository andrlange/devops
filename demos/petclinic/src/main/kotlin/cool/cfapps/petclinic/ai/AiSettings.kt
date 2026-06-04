package cool.cfapps.petclinic.ai

import jakarta.persistence.*
import java.time.LocalDateTime

@Entity
@Table(name = "ai_settings")
class AiSettings(
    @Id
    var id: Long = 1,

    @Column(name = "enabled")
    var enabled: Boolean = false,

    @Column(name = "ollama_url")
    var ollamaUrl: String = "http://192.168.64.1:11434",

    @Column(name = "model_name")
    var modelName: String = "llama3.1:8b",

    @Column(name = "updated_at")
    var updatedAt: LocalDateTime = LocalDateTime.now()
)
