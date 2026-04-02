package cool.cfapps.kappman

import cool.cfapps.kappman.config.KappmanProperties
import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.context.properties.EnableConfigurationProperties
import org.springframework.boot.runApplication

@SpringBootApplication
@EnableConfigurationProperties(KappmanProperties::class)
class KappmanApplication

fun main(args: Array<String>) {
    runApplication<KappmanApplication>(*args)
}
