package @@JAVA_PACKAGE@@.selfhost;

import org.apache.catalina.connector.Connector;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.web.client.RestClientSsl;
import org.springframework.boot.web.embedded.tomcat.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.Ssl;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.web.client.RestClient;

/**
 * windows-selfhost-kit (Spring Boot 3.x): service-to-service mutual TLS.
 * Active only with the "mtls" Spring profile (SPRING_PROFILES_ACTIVE=mtls).
 *
 * <p>Two listeners, because Tailscale Funnel ends TLS itself and cannot pass client certificates:
 * <ul>
 *   <li>SERVER_PORT (e.g. 8080): plain HTTP, published to the internet by Funnel.</li>
 *   <li>MTLS_PORT (default 8443): HTTPS that asks for a client certificate signed by your CA.
 *       Reachable only over the tailnet.</li>
 * </ul>
 * Certificates come from the "mtls" SSL bundle (application-mtls.properties, files in /certs).
 */
@Configuration(proxyBeanMethods = false)
@Profile("mtls")
public class MtlsConfig {

    @Bean
    WebServerFactoryCustomizer<TomcatServletWebServerFactory> mtlsConnectors(
            @Value("${server.port:8080}") int publicPort,
            @Value("${MTLS_PORT:8443}") int mtlsPort,
            @Value("${MTLS_CLIENT_AUTH:want}") String clientAuth) {
        return factory -> {
            Ssl ssl = new Ssl();
            ssl.setBundle("mtls");
            ssl.setClientAuth("need".equalsIgnoreCase(clientAuth.trim()) ? Ssl.ClientAuth.NEED : Ssl.ClientAuth.WANT);
            factory.setSsl(ssl);
            factory.setPort(mtlsPort);

            Connector http = new Connector(TomcatServletWebServerFactory.DEFAULT_PROTOCOL);
            http.setPort(publicPort);
            factory.addAdditionalTomcatConnectors(http);
        };
    }

    /**
     * Calls to other services over mTLS. Map the peer's name to its tailnet IP first
     * (mtls/add-peer.sh), then e.g.:
     * {@code mtlsClients.peer("billing-svc").get().uri("/internal/ping").retrieve().body(String.class)}
     */
    @Bean
    MtlsClients mtlsClients(RestClient.Builder builder, RestClientSsl ssl,
                            @Value("${MTLS_PORT:8443}") int mtlsPort) {
        return serviceName -> builder.clone()
                .apply(ssl.fromBundle("mtls"))
                .baseUrl("https://" + serviceName + ":" + mtlsPort)
                .build();
    }

    @FunctionalInterface
    public interface MtlsClients {
        RestClient peer(String serviceName);
    }
}
