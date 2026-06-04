package cool.cfapps.petclinic.config

import cool.cfapps.petclinic.ai.AiSettingsRepository
import cool.cfapps.petclinic.ai.getSettings
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.ControllerAdvice
import org.springframework.web.bind.annotation.ModelAttribute

@ControllerAdvice
class GlobalModelAttributes(
    private val databaseInfoContributor: DatabaseInfoContributor,
    private val petclinicProperties: PetclinicProperties,
    private val aiSettingsRepository: AiSettingsRepository
) {

    private val runtimeEnvironment: String = detectRuntime()

    @ModelAttribute
    fun addGlobalAttributes(model: Model) {
        model.addAttribute("databaseType", databaseInfoContributor.getDatabaseType())
        model.addAttribute("instanceId", petclinicProperties.instanceId)
        model.addAttribute("techStack", "Spring Boot 4.0.4 / Kotlin 2.3.10 / Thymeleaf")
        model.addAttribute("runtimeEnv", runtimeEnvironment)
        val aiSettings = aiSettingsRepository.getSettings()
        model.addAttribute("aiEnabled", aiSettings.enabled)
        model.addAttribute("aiModel", aiSettings.modelName)
        model.addAttribute("aiOllamaUrl", aiSettings.ollamaUrl)
    }

    private fun detectRuntime(): String = when {
        System.getenv("VCAP_APPLICATION") != null -> "Cloud Foundry"
        System.getenv("KUBERNETES_SERVICE_HOST") != null -> "Kubernetes"
        isRunningInDocker() -> "Docker"
        else -> "Local"
    }

    private fun isRunningInDocker(): Boolean =
        java.io.File("/.dockerenv").exists() ||
        runCatching { java.io.File("/proc/1/cgroup").readText().contains("docker") }.getOrDefault(false)
}
