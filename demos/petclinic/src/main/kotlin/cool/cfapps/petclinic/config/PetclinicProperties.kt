package cool.cfapps.petclinic.config

import org.springframework.boot.context.properties.ConfigurationProperties

@ConfigurationProperties(prefix = "petclinic")
data class PetclinicProperties(
    val instanceId: String = "local"
)
