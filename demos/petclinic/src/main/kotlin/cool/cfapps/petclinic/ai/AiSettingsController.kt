package cool.cfapps.petclinic.ai

import org.springframework.http.ResponseEntity
import org.springframework.stereotype.Controller
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.*
import org.springframework.web.client.RestClient
import org.springframework.web.client.toEntity

@Controller
class AiSettingsController(
    private val aiSettingsRepository: AiSettingsRepository
) {

    @GetMapping("/ai/settings")
    fun settingsPage(model: Model): String {
        val settings = aiSettingsRepository.getSettings()
        model.addAttribute("settings", settings)
        return "ai/settings"
    }

    @PostMapping("/ai/settings")
    fun saveSettings(
        @RequestParam ollamaUrl: String,
        @RequestParam(required = false) modelName: String?,
        @RequestParam(required = false) enabled: Boolean = false,
        model: Model
    ): String {
        val settings = aiSettingsRepository.getSettings()
        settings.ollamaUrl = ollamaUrl.trim()
        if (!modelName.isNullOrBlank()) {
            settings.modelName = modelName.trim()
        }
        settings.enabled = enabled
        settings.updatedAt = java.time.LocalDateTime.now()
        aiSettingsRepository.save(settings)
        return "redirect:/ai/settings"
    }

    @GetMapping("/ai/settings/models")
    @ResponseBody
    fun getModels(): ResponseEntity<String> {
        val settings = aiSettingsRepository.getSettings()
        return try {
            val client = RestClient.builder()
                .baseUrl(settings.ollamaUrl)
                .build()
            val response = client.get()
                .uri("/api/tags")
                .retrieve()
                .toEntity<String>()
            ResponseEntity.status(response.statusCode).body(response.body)
        } catch (e: Exception) {
            ResponseEntity.status(503).body("""{"error":"${e.message?.replace("\"", "'")}"}""")
        }
    }

    @GetMapping("/ai/settings/test")
    @ResponseBody
    fun testConnection(): ResponseEntity<Map<String, Any>> {
        val settings = aiSettingsRepository.getSettings()
        return try {
            val client = RestClient.builder()
                .baseUrl(settings.ollamaUrl)
                .build()
            val response = client.get()
                .uri("/api/tags")
                .retrieve()
                .toEntity<String>()
            if (response.statusCode.is2xxSuccessful) {
                ResponseEntity.ok(mapOf("status" to "ok", "url" to settings.ollamaUrl))
            } else {
                ResponseEntity.status(502).body(mapOf("status" to "error", "message" to "Unexpected status: ${response.statusCode.value()}"))
            }
        } catch (e: Exception) {
            ResponseEntity.status(503).body(mapOf("status" to "error", "message" to (e.message ?: "Connection failed")))
        }
    }

    @PostMapping("/ai/toggle")
    @ResponseBody
    fun toggleAi(): ResponseEntity<Map<String, Any>> {
        val settings = aiSettingsRepository.getSettings()
        settings.enabled = !settings.enabled
        settings.updatedAt = java.time.LocalDateTime.now()
        aiSettingsRepository.save(settings)
        return ResponseEntity.ok(mapOf("enabled" to settings.enabled))
    }

    @GetMapping("/ai/chat")
    fun chatPage(model: Model): String {
        val settings = aiSettingsRepository.getSettings()
        model.addAttribute("settings", settings)
        return "ai/chat"
    }
}
