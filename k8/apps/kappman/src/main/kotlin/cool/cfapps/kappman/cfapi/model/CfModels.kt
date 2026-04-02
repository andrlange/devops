package cool.cfapps.kappman.cfapi.model

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.annotation.JsonProperty

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfPaginatedResponse<T>(
    val pagination: CfPagination? = null,
    val resources: List<T> = emptyList()
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfPagination(
    @JsonProperty("total_results") val totalResults: Int = 0,
    @JsonProperty("total_pages") val totalPages: Int = 0
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfOrg(
    val guid: String = "",
    val name: String = "",
    @JsonProperty("created_at") val createdAt: String? = null,
    val metadata: CfMetadata? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfSpace(
    val guid: String = "",
    val name: String = "",
    @JsonProperty("created_at") val createdAt: String? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfApp(
    val guid: String = "",
    val name: String = "",
    val state: String = "",
    val lifecycle: CfLifecycle? = null,
    @JsonProperty("created_at") val createdAt: String? = null,
    @JsonProperty("updated_at") val updatedAt: String? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfLifecycle(
    val type: String? = null,
    val data: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfProcess(
    val guid: String = "",
    val type: String = "",
    val instances: Int = 0,
    @JsonProperty("memory_in_mb") val memoryInMb: Int = 0,
    @JsonProperty("disk_in_mb") val diskInMb: Int = 0
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfRoute(
    val guid: String = "",
    val host: String = "",
    val path: String = "",
    val url: String = "",
    val destinations: List<CfDestination>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfDestination(
    val guid: String = "",
    val app: CfDestinationApp? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfDestinationApp(
    val guid: String = "",
    val process: CfDestinationProcess? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfDestinationProcess(
    val type: String = ""
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfServiceInstance(
    val guid: String = "",
    val name: String = "",
    val type: String = "",
    @JsonProperty("last_operation") val lastOperation: CfLastOperation? = null,
    @JsonProperty("created_at") val createdAt: String? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfLastOperation(
    val type: String? = null,
    val state: String? = null,
    val description: String? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfServiceOffering(
    val guid: String = "",
    val name: String = "",
    val description: String = "",
    @JsonProperty("broker_catalog") val brokerCatalog: Map<String, Any>? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfServicePlan(
    val guid: String = "",
    val name: String = "",
    val description: String = "",
    val free: Boolean = true,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfServiceBinding(
    val guid: String = "",
    val type: String = "",
    val name: String? = null,
    @JsonProperty("created_at") val createdAt: String? = null,
    val relationships: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfBuildpack(
    val guid: String = "",
    val name: String = "",
    val stack: String? = null,
    val state: String? = null,
    val position: Int = 0,
    val enabled: Boolean = true
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfInfo(
    val build: String? = null,
    @JsonProperty("cli_version") val cliVersion: Map<String, String>? = null,
    val name: String? = null,
    val version: String? = null,
    val description: String? = null,
    val links: Map<String, Any>? = null
)

@JsonIgnoreProperties(ignoreUnknown = true)
data class CfMetadata(
    val labels: Map<String, String>? = null,
    val annotations: Map<String, String>? = null
)
