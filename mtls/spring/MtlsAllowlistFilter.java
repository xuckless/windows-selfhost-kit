package @@JAVA_PACKAGE@@.selfhost;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.security.cert.CertificateParsingException;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * windows-selfhost-kit: decides who may call this service on the mTLS port.
 *
 * <ul>
 *   <li>Requests on the public port (behind Tailscale Funnel) to MTLS_ONLY_PATHS
 *       (default "/internal/") get 404, so internal endpoints are only reachable with mTLS.</li>
 *   <li>Requests on the mTLS port: the client certificate's name (CN or DNS SAN) must be
 *       in MTLS_ALLOWED_CLIENTS (empty = any certificate signed by your CA).
 *       With MTLS_CLIENT_AUTH=want (rollout mode) problems are only logged;
 *       with MTLS_CLIENT_AUTH=need they are rejected (no certificate = TLS refused,
 *       wrong name = 403).</li>
 * </ul>
 * The caller's service name is available to controllers as request attribute "mtls.client".
 */
@Component
@Profile("mtls")
@Order(Ordered.HIGHEST_PRECEDENCE + 10)
public class MtlsAllowlistFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(MtlsAllowlistFilter.class);

    private final int mtlsPort;
    private final boolean enforce;
    private final Set<String> allowed;
    private final List<String> mtlsOnlyPaths;

    public MtlsAllowlistFilter(@Value("${MTLS_PORT:8443}") int mtlsPort,
                               @Value("${MTLS_CLIENT_AUTH:want}") String clientAuth,
                               @Value("${MTLS_ALLOWED_CLIENTS:}") String allowedClients,
                               @Value("${MTLS_ONLY_PATHS:/internal/}") String mtlsOnlyPaths) {
        this.mtlsPort = mtlsPort;
        this.enforce = "need".equalsIgnoreCase(clientAuth.trim());
        this.allowed = split(allowedClients).stream().collect(Collectors.toSet());
        this.mtlsOnlyPaths = split(mtlsOnlyPaths);
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        String path = request.getRequestURI();
        if (request.getLocalPort() != mtlsPort) {
            if (mtlsOnlyPaths.stream().anyMatch(path::startsWith)) {
                response.sendError(HttpServletResponse.SC_NOT_FOUND);
                return;
            }
            chain.doFilter(request, response);
            return;
        }

        X509Certificate[] chainCerts =
                (X509Certificate[]) request.getAttribute("jakarta.servlet.request.X509Certificate");
        if (chainCerts == null || chainCerts.length == 0) {
            log.warn("mTLS: request to {} without a client certificate (allowed only in want mode)", path);
            chain.doFilter(request, response);
            return;
        }

        List<String> names = namesOf(chainCerts[0]);
        String client = names.isEmpty() ? "?" : names.get(0);
        boolean ok = allowed.isEmpty() || names.stream().anyMatch(allowed::contains);
        if (!ok) {
            if (enforce) {
                log.warn("mTLS: rejected {} calling {} (not in MTLS_ALLOWED_CLIENTS)", names, path);
                response.sendError(HttpServletResponse.SC_FORBIDDEN);
                return;
            }
            log.warn("mTLS: {} calling {} is not in MTLS_ALLOWED_CLIENTS (allowed: want mode)", names, path);
        }
        request.setAttribute("mtls.client", client);
        chain.doFilter(request, response);
    }

    private static List<String> namesOf(X509Certificate cert) {
        List<String> names = new ArrayList<>();
        try {
            for (Rdn rdn : new LdapName(cert.getSubjectX500Principal().getName()).getRdns()) {
                if ("CN".equalsIgnoreCase(rdn.getType())) {
                    names.add(String.valueOf(rdn.getValue()));
                }
            }
        } catch (InvalidNameException ignored) {
            // no usable subject name
        }
        try {
            Collection<List<?>> sans = cert.getSubjectAlternativeNames();
            if (sans != null) {
                for (List<?> san : sans) {
                    if (san.size() == 2 && Integer.valueOf(2).equals(san.get(0))) {
                        names.add(String.valueOf(san.get(1)));
                    }
                }
            }
        } catch (CertificateParsingException ignored) {
            // no usable SAN
        }
        return names.stream().distinct().toList();
    }

    private static List<String> split(String csv) {
        return Arrays.stream(csv.split(",")).map(String::trim).filter(s -> !s.isEmpty()).toList();
    }
}
