package cool.cfapps.kappman.cfapi

import cool.cfapps.kappman.config.KappmanProperties
import org.springframework.http.HttpHeaders
import org.springframework.stereotype.Component
import org.springframework.web.reactive.function.client.WebClient
import org.springframework.web.reactive.function.client.WebClientResponseException
import java.util.concurrent.atomic.AtomicReference
import java.util.logging.Logger

@Component
class CfApiClient(
    private val cfWebClient: WebClient,
    private val kappmanProperties: KappmanProperties
) {
    private val logger = Logger.getLogger(CfApiClient::class.java.name)
    private val authToken = AtomicReference<String?>()

    private fun ensureAuthenticated() {
        if (authToken.get() != null) return

        val password = kappmanProperties.cfApi.password
        if (password.isBlank()) {
            logger.warning("CF API password not configured — API calls will fail")
            return
        }

        // If password looks like a bearer token, use it directly
        if (password.startsWith("ey") || password.length > 100) {
            authToken.set(password)
            logger.info("Using configured token for CF API authentication")
            return
        }

        // Try basic auth login via CF API
        try {
            val response = cfWebClient.get()
                .uri("/")
                .headers { it.setBasicAuth(kappmanProperties.cfApi.username, password) }
                .retrieve()
                .bodyToMono(String::class.java)
                .block()
            // If basic auth works, store the credentials as-is for subsequent calls
            authToken.set("basic")
            logger.info("CF API authentication via basic auth successful")
        } catch (e: Exception) {
            logger.warning("CF API authentication failed: ${e.message}")
        }
    }

    fun <T : Any> get(path: String, responseType: Class<T>): T? {
        ensureAuthenticated()
        return try {
            cfWebClient.get()
                .uri(path)
                .headers { addAuth(it) }
                .retrieve()
                .bodyToMono(responseType)
                .block()
        } catch (e: WebClientResponseException.Unauthorized) {
            authToken.set(null)
            ensureAuthenticated()
            cfWebClient.get()
                .uri(path)
                .headers { addAuth(it) }
                .retrieve()
                .bodyToMono(responseType)
                .block()
        } catch (e: Exception) {
            logger.warning("CF API GET $path failed: ${e.message}")
            null
        }
    }

    fun <T : Any> post(path: String, body: Any?, responseType: Class<T>): T? {
        ensureAuthenticated()
        return try {
            val request = cfWebClient.post().uri(path).headers { addAuth(it) }
            val spec = if (body != null) request.bodyValue(body) else request
            spec.retrieve().bodyToMono(responseType).block()
        } catch (e: Exception) {
            logger.warning("CF API POST $path failed: ${e.message}")
            null
        }
    }

    fun <T : Any> patch(path: String, body: Any?, responseType: Class<T>): T? {
        ensureAuthenticated()
        return try {
            val request = cfWebClient.patch().uri(path).headers { addAuth(it) }
            val spec = if (body != null) request.bodyValue(body) else request
            spec.retrieve().bodyToMono(responseType).block()
        } catch (e: Exception) {
            logger.warning("CF API PATCH $path failed: ${e.message}")
            null
        }
    }

    fun delete(path: String): Boolean {
        ensureAuthenticated()
        return try {
            cfWebClient.delete()
                .uri(path)
                .headers { addAuth(it) }
                .retrieve()
                .toBodilessEntity()
                .block()
            true
        } catch (e: Exception) {
            logger.warning("CF API DELETE $path failed: ${e.message}")
            false
        }
    }

    fun isConfigured(): Boolean = kappmanProperties.cfApi.password.isNotBlank()

    private fun addAuth(headers: HttpHeaders) {
        val token = authToken.get() ?: return
        if (token == "basic") {
            headers.setBasicAuth(kappmanProperties.cfApi.username, kappmanProperties.cfApi.password)
        } else {
            headers.setBearerAuth(token)
        }
    }
}
