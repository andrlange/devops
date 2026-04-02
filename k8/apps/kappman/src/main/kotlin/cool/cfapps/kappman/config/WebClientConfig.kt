package cool.cfapps.kappman.config

import io.netty.handler.ssl.SslContextBuilder
import io.netty.handler.ssl.util.InsecureTrustManagerFactory
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.http.client.reactive.ReactorClientHttpConnector
import org.springframework.web.reactive.function.client.WebClient
import reactor.netty.http.client.HttpClient

@Configuration
class WebClientConfig(
    private val kappmanProperties: KappmanProperties
) {

    @Bean
    fun cfWebClient(): WebClient {
        val builder = WebClient.builder()
            .baseUrl(kappmanProperties.cfApi.url)

        if (kappmanProperties.cfApi.skipSsl) {
            val sslContext = SslContextBuilder.forClient()
                .trustManager(InsecureTrustManagerFactory.INSTANCE)
                .build()
            val httpClient = HttpClient.create()
                .secure { it.sslContext(sslContext) }
            builder.clientConnector(ReactorClientHttpConnector(httpClient))
        }

        return builder.build()
    }
}
