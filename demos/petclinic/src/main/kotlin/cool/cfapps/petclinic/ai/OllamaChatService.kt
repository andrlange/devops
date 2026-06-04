package cool.cfapps.petclinic.ai

import org.springframework.ai.chat.client.ChatClient
import org.springframework.ai.ollama.OllamaChatModel
import org.springframework.ai.ollama.api.OllamaApi
import org.springframework.ai.ollama.api.OllamaChatOptions
import org.springframework.stereotype.Service
import reactor.core.publisher.Flux
import java.util.concurrent.atomic.AtomicReference

@Service
class OllamaChatService(
    private val settingsRepository: AiSettingsRepository
) {
    private val chatClientRef = AtomicReference<ChatClient?>(null)
    private val lastUrl = AtomicReference<String?>(null)
    private val lastModel = AtomicReference<String?>(null)

    companion object {
        const val SYSTEM_PROMPT = """You are a friendly and knowledgeable veterinary AI assistant for a pet clinic.
Your role is to provide helpful information about pet health, nutrition, vaccinations, and general care.

IMPORTANT RULES:
1. Always include a disclaimer that you are not a substitute for professional veterinary care.
2. For emergencies, always recommend contacting a veterinarian immediately.
3. Base your answers on the provided knowledge base context when available.
4. If no knowledge base context is provided, answer from your general knowledge but note this.
5. Be empathetic and supportive in your responses.
6. Keep responses concise but informative.
7. When discussing a specific pet, reference their details (name, age, type) naturally.
8. Use the current date and the pet's age provided in the context to answer time-sensitive questions such as life expectancy, vaccination schedules, or age-related health concerns. Calculate remaining years based on typical breed/species lifespan."""
    }

    fun getChatClient(): ChatClient {
        val settings = settingsRepository.getSettings()
        val url = settings.ollamaUrl
        val model = settings.modelName

        if (url != lastUrl.get() || model != lastModel.get()) {
            val ollamaApi = OllamaApi.builder()
                .baseUrl(url)
                .build()
            val chatOptions = OllamaChatOptions.builder()
                .model(model)
                .build()
            val chatModel = OllamaChatModel.builder()
                .ollamaApi(ollamaApi)
                .defaultOptions(chatOptions)
                .build()
            val client = ChatClient.builder(chatModel)
                .defaultSystem(SYSTEM_PROMPT)
                .build()
            chatClientRef.set(client)
            lastUrl.set(url)
            lastModel.set(model)
        }
        return chatClientRef.get() ?: throw IllegalStateException("ChatClient not initialized")
    }

    fun streamChat(userMessage: String, context: String): Flux<String> {
        val client = getChatClient()
        val fullPrompt = if (context.isNotBlank()) {
            """Here is relevant context for answering the question:

$context

User question: $userMessage"""
        } else {
            userMessage
        }

        return client.prompt()
            .user(fullPrompt)
            .stream()
            .content()
    }

    fun isAvailable(): Boolean {
        return try {
            val settings = settingsRepository.getSettings()
            if (!settings.enabled) return false
            val url = settings.ollamaUrl
            val connection = java.net.URI(url).toURL().openConnection() as java.net.HttpURLConnection
            connection.connectTimeout = 3000
            connection.readTimeout = 3000
            connection.requestMethod = "GET"
            connection.responseCode == 200
        } catch (e: Exception) {
            false
        }
    }
}
