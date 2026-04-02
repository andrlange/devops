package cool.cfapps.kappman.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "kappman")
data class KappmanProperties(
    val cfApi: CfApiProperties = CfApiProperties(),
    val instanceId: String = "local"
) {
    data class CfApiProperties(
        val url: String = "https://api.app.cfapps.cool",
        val username: String = "cf-admin",
        val password: String = "",
        val skipSsl: Boolean = true
    )
}
