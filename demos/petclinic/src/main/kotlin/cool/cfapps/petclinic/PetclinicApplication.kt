package cool.cfapps.petclinic

import cool.cfapps.petclinic.config.PetclinicProperties
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.boot.runApplication

@SpringBootApplication
@EnableConfigurationProperties(PetclinicProperties::class)
class PetclinicApplication

fun main(args: Array<String>) {
    runApplication<PetclinicApplication>(*args)
}
