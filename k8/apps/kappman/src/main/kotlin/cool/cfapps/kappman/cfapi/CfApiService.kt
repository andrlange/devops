package cool.cfapps.kappman.cfapi

import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import cool.cfapps.kappman.cfapi.model.*
import org.springframework.core.ParameterizedTypeReference
import org.springframework.stereotype.Service
import org.springframework.web.reactive.function.client.WebClient
import org.springframework.web.reactive.function.client.WebClientResponseException
import java.util.logging.Logger

@Service
class CfApiService(
    private val cfApiClient: CfApiClient
) {
    private val objectMapper: ObjectMapper = ObjectMapper().apply {
        findAndRegisterModules()
    }
    private val logger = Logger.getLogger(CfApiService::class.java.name)

    fun isConfigured(): Boolean = cfApiClient.isConfigured()

    // Info
    fun getInfo(): CfInfo? = cfApiClient.get("/v3/info", CfInfo::class.java)

    // Organizations
    fun listOrgs(): List<CfOrg> {
        val json = cfApiClient.get("/v3/organizations", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun createOrg(name: String): CfOrg? {
        return cfApiClient.post("/v3/organizations", mapOf("name" to name), CfOrg::class.java)
    }

    fun deleteOrg(guid: String): Boolean = cfApiClient.delete("/v3/organizations/$guid")

    // Spaces
    fun listSpaces(orgGuid: String? = null): List<CfSpace> {
        val path = if (orgGuid != null) "/v3/spaces?organization_guids=$orgGuid" else "/v3/spaces"
        val json = cfApiClient.get(path, String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun createSpace(name: String, orgGuid: String): CfSpace? {
        val body = mapOf(
            "name" to name,
            "relationships" to mapOf(
                "organization" to mapOf("data" to mapOf("guid" to orgGuid))
            )
        )
        return cfApiClient.post("/v3/spaces", body, CfSpace::class.java)
    }

    fun deleteSpace(guid: String): Boolean = cfApiClient.delete("/v3/spaces/$guid")

    // Apps
    fun listApps(spaceGuid: String? = null): List<CfApp> {
        val path = if (spaceGuid != null) "/v3/apps?space_guids=$spaceGuid" else "/v3/apps"
        val json = cfApiClient.get(path, String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun getApp(guid: String): CfApp? = cfApiClient.get("/v3/apps/$guid", CfApp::class.java)

    fun startApp(guid: String): CfApp? {
        return cfApiClient.post("/v3/apps/$guid/actions/start", null, CfApp::class.java)
    }

    fun stopApp(guid: String): CfApp? {
        return cfApiClient.post("/v3/apps/$guid/actions/stop", null, CfApp::class.java)
    }

    fun restartApp(guid: String): CfApp? {
        return cfApiClient.post("/v3/apps/$guid/actions/restart", null, CfApp::class.java)
    }

    fun scaleApp(guid: String, instances: Int? = null, memoryInMb: Int? = null, diskInMb: Int? = null): CfProcess? {
        val body = mutableMapOf<String, Any>()
        instances?.let { body["instances"] = it }
        memoryInMb?.let { body["memory_in_mb"] = it }
        diskInMb?.let { body["disk_in_mb"] = it }
        return cfApiClient.post("/v3/apps/$guid/processes/web/actions/scale", body, CfProcess::class.java)
    }

    fun getAppProcesses(guid: String): List<CfProcess> {
        val json = cfApiClient.get("/v3/apps/$guid/processes", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun getAppRoutes(guid: String): List<CfRoute> {
        val json = cfApiClient.get("/v3/apps/$guid/routes", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun getAppEnv(guid: String): Map<String, Any>? {
        return cfApiClient.get("/v3/apps/$guid/env", Map::class.java) as? Map<String, Any>
    }

    fun setAppEnv(guid: String, envVars: Map<String, String>): Boolean {
        val body = mapOf("var" to envVars)
        return cfApiClient.patch("/v3/apps/$guid/environment_variables", body, Map::class.java) != null
    }

    fun deleteApp(guid: String): Boolean = cfApiClient.delete("/v3/apps/$guid")

    // Logs - graceful fallback since Korifi may not support standard log endpoints
    fun getAppLogs(guid: String): String {
        return try {
            // Korifi uses logcache-compatible endpoint
            val json = cfApiClient.get("/api/v1/read/$guid?envelope_types=LOG&descending=true&limit=100", String::class.java)
            if (json != null) {
                parseLogEnvelopes(json)
            } else {
                "No logs available."
            }
        } catch (e: Exception) {
            logger.warning("Failed to fetch logs for $guid: ${e.message}")
            "No logs available."
        }
    }

    private fun parseLogEnvelopes(json: String): String {
        return try {
            val tree = objectMapper.readTree(json)
            val batch = tree.path("envelopes").path("batch")
            if (batch.isMissingNode || !batch.isArray || batch.size() == 0) {
                return "No log entries."
            }
            val lines = mutableListOf<String>()
            for (envelope in batch) {
                val payload = envelope.path("log").path("payload").asText("")
                if (payload.isNotBlank()) {
                    val decoded = java.util.Base64.getDecoder().decode(payload).toString(Charsets.UTF_8).trimEnd()
                    lines.add(decoded)
                }
            }
            if (lines.isEmpty()) "No log entries." else lines.joinToString("\n")
        } catch (e: Exception) {
            logger.warning("Failed to parse log envelopes: ${e.message}")
            "Failed to parse logs."
        }
    }

    // Service Instances
    fun listServiceInstances(spaceGuid: String? = null): List<CfServiceInstance> {
        val path = if (spaceGuid != null) "/v3/service_instances?space_guids=$spaceGuid" else "/v3/service_instances"
        val json = cfApiClient.get(path, String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun createServiceInstance(name: String, spaceGuid: String, planGuid: String): CfServiceInstance? {
        val body = mapOf(
            "type" to "managed",
            "name" to name,
            "relationships" to mapOf(
                "space" to mapOf("data" to mapOf("guid" to spaceGuid)),
                "service_plan" to mapOf("data" to mapOf("guid" to planGuid))
            )
        )
        return cfApiClient.post("/v3/service_instances", body, CfServiceInstance::class.java)
    }

    fun deleteServiceInstance(guid: String): Boolean = cfApiClient.delete("/v3/service_instances/$guid")

    // Service Bindings
    fun listBindings(appGuid: String? = null, serviceInstanceGuid: String? = null): List<CfServiceBinding> {
        val params = mutableListOf<String>()
        appGuid?.let { params.add("app_guids=$it") }
        serviceInstanceGuid?.let { params.add("service_instance_guids=$it") }
        val query = if (params.isNotEmpty()) "?" + params.joinToString("&") else ""
        val json = cfApiClient.get("/v3/service_credential_bindings$query", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun createBinding(appGuid: String, serviceInstanceGuid: String): CfServiceBinding? {
        val body = mapOf(
            "type" to "app",
            "relationships" to mapOf(
                "app" to mapOf("data" to mapOf("guid" to appGuid)),
                "service_instance" to mapOf("data" to mapOf("guid" to serviceInstanceGuid))
            )
        )
        return cfApiClient.post("/v3/service_credential_bindings", body, CfServiceBinding::class.java)
    }

    fun deleteBinding(guid: String): Boolean = cfApiClient.delete("/v3/service_credential_bindings/$guid")

    // Service Offerings & Plans
    fun listOfferings(): List<CfServiceOffering> {
        val json = cfApiClient.get("/v3/service_offerings", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    fun listPlans(offeringGuid: String? = null): List<CfServicePlan> {
        val path = if (offeringGuid != null) "/v3/service_plans?service_offering_guids=$offeringGuid" else "/v3/service_plans"
        val json = cfApiClient.get(path, String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    // Buildpacks
    fun listBuildpacks(): List<CfBuildpack> {
        val json = cfApiClient.get("/v3/buildpacks", String::class.java) ?: return emptyList()
        return parsePaginatedResponse(json)
    }

    // Helper to parse paginated responses
    private inline fun <reified T> parsePaginatedResponse(json: String): List<T> {
        return try {
            val tree = objectMapper.readTree(json)
            val resources = tree.get("resources") ?: return emptyList()
            objectMapper.readValue<List<T>>(resources.toString())
        } catch (e: Exception) {
            logger.warning("Failed to parse CF API response: ${e.message}")
            emptyList()
        }
    }
}
