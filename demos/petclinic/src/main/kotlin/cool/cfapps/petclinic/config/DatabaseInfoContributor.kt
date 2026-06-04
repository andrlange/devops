package cool.cfapps.petclinic.config

import jakarta.annotation.PostConstruct
import org.springframework.stereotype.Component
import javax.sql.DataSource

@Component
class DatabaseInfoContributor(private val dataSource: DataSource) {

    private var databaseType: String = "Unknown"

    @PostConstruct
    fun detectDatabaseType() {
        try {
            dataSource.connection.use { connection ->
                val metaData = connection.metaData
                val productName = metaData.databaseProductName
                databaseType = when {
                    productName.contains("H2", ignoreCase = true) -> "H2"
                    productName.contains("PostgreSQL", ignoreCase = true) -> "PostgreSQL"
                    else -> productName
                }
            }
        } catch (e: Exception) {
            databaseType = "Unknown"
        }
    }

    fun getDatabaseType(): String = databaseType
}
