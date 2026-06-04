package cool.cfapps.petclinic.ai

import tools.jackson.databind.ObjectMapper
import cool.cfapps.petclinic.pet.PetRepository
import cool.cfapps.petclinic.visit.VisitRepository
import org.springframework.messaging.handler.annotation.MessageMapping
import org.springframework.messaging.handler.annotation.Payload
import org.springframework.messaging.simp.SimpMessagingTemplate
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RestController
import java.time.LocalDateTime

data class ChatMessage(
    val content: String = "",
    val sessionId: String = "",
    val petId: Long? = null
)

data class ChatResponse(
    val type: String,
    val content: String = "",
    val sessionId: String = ""
)

@RestController
class AiChatController(
    private val messagingTemplate: SimpMessagingTemplate,
    private val ollamaChatService: OllamaChatService,
    private val vetKnowledgeService: VetKnowledgeService,
    private val chatMessageRepository: AiChatMessageRepository,
    private val petRepository: PetRepository,
    private val visitRepository: VisitRepository,
    private val objectMapper: ObjectMapper
) {

    @MessageMapping("/chat.send")
    fun handleChatMessage(@Payload chatMessage: ChatMessage) {
        val destination = "/topic/chat.${chatMessage.sessionId}"

        try {
            // Load pet context if petId is provided
            val pet = chatMessage.petId?.let { petRepository.findById(it).orElse(null) }
            val visits = pet?.let { visitRepository.findByPetId(it.id) } ?: emptyList()

            // Run FTS retrieval
            val petType = pet?.type?.name
            val articles = vetKnowledgeService.searchKnowledge(chatMessage.content, petType)

            // Send source references first
            if (articles.isNotEmpty()) {
                val sourcesList = articles.map { mapOf("title" to it.title, "category" to it.category) }
                val sourcesJson = objectMapper.writeValueAsString(sourcesList)
                messagingTemplate.convertAndSend(
                    destination,
                    ChatResponse(type = "sources", content = sourcesJson, sessionId = chatMessage.sessionId)
                )
            }

            // Build context
            val context = vetKnowledgeService.buildContext(articles, pet, visits)

            // Accumulate full response for persistence
            val fullResponse = StringBuilder()

            // Stream Ollama response token-by-token
            ollamaChatService.streamChat(chatMessage.content, context)
                .doOnNext { token ->
                    fullResponse.append(token)
                    messagingTemplate.convertAndSend(
                        destination,
                        ChatResponse(type = "token", content = token, sessionId = chatMessage.sessionId)
                    )
                }
                .doOnComplete {
                    messagingTemplate.convertAndSend(
                        destination,
                        ChatResponse(type = "done", content = "", sessionId = chatMessage.sessionId)
                    )

                    // Persist messages for pet chats
                    if (pet != null) {
                        val knowledgeRefs = if (articles.isNotEmpty()) {
                            articles.joinToString(", ") { it.title }
                        } else null

                        val userMessage = AiChatMessage(
                            pet = pet,
                            sessionId = chatMessage.sessionId,
                            role = "user",
                            content = chatMessage.content,
                            createdAt = LocalDateTime.now()
                        )
                        chatMessageRepository.save(userMessage)

                        val assistantMessage = AiChatMessage(
                            pet = pet,
                            sessionId = chatMessage.sessionId,
                            role = "assistant",
                            content = fullResponse.toString(),
                            knowledgeRefs = knowledgeRefs,
                            createdAt = LocalDateTime.now()
                        )
                        chatMessageRepository.save(assistantMessage)
                    }
                }
                .doOnError { error ->
                    messagingTemplate.convertAndSend(
                        destination,
                        ChatResponse(
                            type = "error",
                            content = error.message ?: "An error occurred",
                            sessionId = chatMessage.sessionId
                        )
                    )
                }
                .subscribe()

        } catch (e: Exception) {
            messagingTemplate.convertAndSend(
                destination,
                ChatResponse(type = "error", content = e.message ?: "An error occurred", sessionId = chatMessage.sessionId)
            )
        }
    }

    @GetMapping("/ai/chat/history/{petId}")
    fun getChatHistory(@PathVariable petId: Long): List<Map<String, Any?>> {
        val messages = chatMessageRepository.findByPetIdOrderByCreatedAtAsc(petId)
        return messages.map { msg ->
            mapOf(
                "id" to msg.id,
                "sessionId" to msg.sessionId,
                "role" to msg.role,
                "content" to msg.content,
                "knowledgeRefs" to msg.knowledgeRefs,
                "createdAt" to msg.createdAt.toString()
            )
        }
    }

    @GetMapping("/ai/chat/sessions/{petId}")
    fun getChatSessions(@PathVariable petId: Long): List<Map<String, Any?>> {
        val messages = chatMessageRepository.findByPetIdOrderByCreatedAtAsc(petId)
        return messages
            .groupBy { it.sessionId }
            .map { (sessionId, sessionMessages) ->
                val first = sessionMessages.first()
                val preview = first.content.take(80) + if (first.content.length > 80) "..." else ""
                mapOf(
                    "sessionId" to sessionId,
                    "preview" to preview,
                    "date" to first.createdAt.toLocalDate().toString(),
                    "messageCount" to sessionMessages.size
                )
            }
            .sortedByDescending { it["date"] as String }
    }
}
