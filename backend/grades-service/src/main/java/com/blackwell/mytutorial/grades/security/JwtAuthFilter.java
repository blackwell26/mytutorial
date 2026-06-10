package com.blackwell.mytutorial.grades.security;

import jakarta.servlet.*;
import jakarta.servlet.http.*;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.List;

/**
 * Authenticates requests reaching grades-service.
 *
 * Strategy (in priority order):
 *
 * 1. X-Authenticated-User header — set by the api-gateway after it has already
 *    validated the JWT. When requests come through the gateway we trust this
 *    header and skip re-parsing the token.
 *
 * 2. Authorization: Bearer <token> — direct requests that bypass the gateway
 *    (e.g. dev/testing tools hitting port 8082 directly). The JWT is validated
 *    locally using the shared secret.
 *
 * If neither is present the filter chain continues without authentication and
 * Spring Security's authorization layer will reject the request with 401.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class JwtAuthFilter extends OncePerRequestFilter {

    private final JwtTokenProvider jwtTokenProvider;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain)
            throws ServletException, IOException {

        String username = resolveFromGatewayHeader(request);

        if (username == null) {
            // Fallback: direct call with Bearer token (dev / testing)
            username = resolveFromBearerToken(request);
        }

        if (username != null) {
            UsernamePasswordAuthenticationToken auth =
                    new UsernamePasswordAuthenticationToken(
                            username, null,
                            List.of(new SimpleGrantedAuthority("ROLE_USER")));
            SecurityContextHolder.getContext().setAuthentication(auth);
            log.debug("Authenticated user '{}' for {}", username, request.getRequestURI());
        } else {
            log.debug("No authentication credentials found for {}", request.getRequestURI());
        }

        filterChain.doFilter(request, response);
    }

    /**
     * Reads the X-Authenticated-User header injected by the api-gateway.
     * The gateway only sets this header after successfully validating the JWT,
     * so we can trust it without re-parsing the token.
     */
    private String resolveFromGatewayHeader(HttpServletRequest request) {
        String user = request.getHeader("X-Authenticated-User");
        if (StringUtils.hasText(user)) {
            log.debug("Resolved user '{}' from X-Authenticated-User header", user);
            return user;
        }
        return null;
    }

    /**
     * Falls back to validating a Bearer JWT directly.
     * Used when grades-service is called directly (bypassing the gateway).
     */
    private String resolveFromBearerToken(HttpServletRequest request) {
        String bearer = request.getHeader("Authorization");
        if (StringUtils.hasText(bearer) && bearer.startsWith("Bearer ")) {
            String token = bearer.substring(7);
            if (jwtTokenProvider.validateToken(token)) {
                return jwtTokenProvider.getUsernameFromToken(token);
            }
        }
        return null;
    }
}
