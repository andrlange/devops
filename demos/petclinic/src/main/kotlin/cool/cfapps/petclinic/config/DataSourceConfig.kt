package cool.cfapps.petclinic.config

import org.springframework.boot.SpringApplication
import org.springframework.boot.EnvironmentPostProcessor
import org.springframework.core.env.ConfigurableEnvironment
import org.springframework.core.env.MapPropertySource
import java.sql.DriverManager
import java.util.logging.Logger

class DataSourceConfig : EnvironmentPostProcessor {

    private val logger: Logger = Logger.getLogger(DataSourceConfig::class.java.name)

    override fun postProcessEnvironment(environment: ConfigurableEnvironment, application: SpringApplication) {
        val url = environment.getProperty("spring.datasource.url") ?: return
        if (!url.contains("postgresql", ignoreCase = true)) return

        if (!isPostgresReachable(url, environment)) {
            logger.warning("PostgreSQL is not reachable at $url — falling back to H2 in-memory database")
            val activeProfiles = environment.activeProfiles.toMutableList()
            activeProfiles.add("h2")
            val props = mapOf("spring.profiles.active" to activeProfiles.joinToString(","))
            environment.propertySources.addFirst(MapPropertySource("h2Fallback", props))
        }
    }

    private fun isPostgresReachable(url: String, environment: ConfigurableEnvironment): Boolean {
        val username = environment.getProperty("spring.datasource.username") ?: ""
        val password = environment.getProperty("spring.datasource.password") ?: ""
        return try {
            DriverManager.setLoginTimeout(2)
            DriverManager.getConnection(url, username, password).use { true }
        } catch (e: Exception) {
            false
        }
    }
}
