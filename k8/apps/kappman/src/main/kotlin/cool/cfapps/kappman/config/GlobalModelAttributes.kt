package cool.cfapps.kappman.config

import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.ui.Model
import org.springframework.web.bind.annotation.ControllerAdvice
import org.springframework.web.bind.annotation.ModelAttribute

@ControllerAdvice
class GlobalModelAttributes(
    private val kappmanProperties: KappmanProperties
) {
    private val runtimeEnvironment: String = detectRuntime()

    @ModelAttribute
    fun addGlobalAttributes(model: Model) {
        model.addAttribute("runtimeEnv", runtimeEnvironment)
        model.addAttribute("instanceId", kappmanProperties.instanceId)
        model.addAttribute("appVersion", "V1.1.0")
        val auth = SecurityContextHolder.getContext().authentication
        if (auth != null && auth.isAuthenticated && auth.name != "anonymousUser") {
            model.addAttribute("currentUsername", auth.name)
        }
    }

    private fun detectRuntime(): String = when {
        System.getenv("VCAP_APPLICATION") != null -> "Cloud Foundry"
        System.getenv("KUBERNETES_SERVICE_HOST") != null -> "Kubernetes"
        isRunningInDocker() -> "Docker"
        else -> "Local"
    }

    private fun isRunningInDocker(): Boolean = try {
        java.io.File("/.dockerenv").exists()
    } catch (e: Exception) {
        false
    }
}
