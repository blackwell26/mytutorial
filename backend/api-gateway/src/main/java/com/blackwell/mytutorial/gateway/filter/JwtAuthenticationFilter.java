package com.blackwell.mytutorial.gateway.filter;

import com.blackwell.mytutorial.gateway.security.JwtTokenProvider;
import lombok.extern.slf4j.Slf4j;
import org.springframework.cloud.gateway.filter.GatewayFilter;
import org.springframework.cloud.gateway.filter.factory.AbstractGatewayFilterFactory;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;

/**
 * Spring Cloud Gateway filter that validates the Bearer JWT on protected routes.
 * Referenced in application.yml as "JwtAuthenticationFilter".
 *
 * Behaviour:
 *  - OPTIONS preflight requests are passed through immediately (required for CORS).
 *  - All other requests must carry a valid Bearer JWT in the Authorization header.
 *  - After validation the username is forwarded as X-Authenticated-User so
 *    downstream services don't need to re-validate the token.
 */
@Slf4j
@Component
public class JwtAuthenticationFilter
        extends AbstractGatewayFilterFactory<JwtAuthenticationFilter.Config> {

    private final JwtTokenProvider jwtTokenProvider;

    public JwtAuthenticationFilter(JwtTokenProvider jwtTokenProvider) {
        super(Config.class);
        this.jwtTokenProvider = jwtTokenProvider;
    }

    @Override
    public GatewayFilter apply(Config config) {
        return (exchange, chain) -> {

            // Always pass OPTIONS preflight through — CORS headers are added by
            // the global CORS config before this filter runs, but we must not block.
            if (HttpMethod.OPTIONS.equals(exchange.getRequest().getMethod())) {
                return chain.filter(exchange);
            }

            String authHeader = exchange.getRequest()
                    .getHeaders()
                    .getFirst(HttpHeaders.AUTHORIZATION);

            if (!StringUtils.hasText(authHeader) || !authHeader.startsWith("Bearer ")) {
                log.warn("Missing or malformed Authorization header on {}",
                        exchange.getRequest().getPath());
                exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
                return exchange.getResponse().setComplete();
            }

            String token = authHeader.substring(7);
            if (!jwtTokenProvider.validateToken(token)) {
                log.warn("Invalid or expired JWT on {}", exchange.getRequest().getPath());
                exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
                return exchange.getResponse().setComplete();
            }

            // Inject validated username as a trusted internal header.
            // Downstream services read X-Authenticated-User instead of re-parsing the JWT.
            String username = jwtTokenProvider.getUsernameFromToken(token);
            var mutatedRequest = exchange.getRequest().mutate()
                    .header("X-Authenticated-User", username)
                    .build();

            log.debug("JWT valid — forwarding '{}' to {}", username,
                    exchange.getRequest().getPath());

            return chain.filter(exchange.mutate().request(mutatedRequest).build());
        };
    }

    public static class Config {
        // Placeholder for future per-route config (e.g. required roles)
    }
}
