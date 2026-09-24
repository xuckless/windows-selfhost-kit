package @@JAVA_PACKAGE@@;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * Starts a throwaway Postgres in Docker for tests (Spring Boot 3.x).
 * Used by the CI "test" job so that @SpringBootTest can load a context that needs a database.
 * Enable it on your test class with: @Import(SelfhostTestcontainersConfiguration.class)
 */
@TestConfiguration(proxyBeanMethods = false)
public class SelfhostTestcontainersConfiguration {

    @Bean
    @ServiceConnection
    PostgreSQLContainer<?> postgresContainer() {
        return new PostgreSQLContainer<>(DockerImageName.parse("postgres:17-alpine"));
    }
}
