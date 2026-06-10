package com.blackwell.mytutorial.gateway.controller;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

import java.util.Map;

/**
 * Circuit breaker fallback endpoint — returned when a downstream service
 * is unavailable.  Uses reactive Mono because the gateway is WebFlux-based.
 */
@RestController
@RequestMapping("/fallback")
public class FallbackController {

    @GetMapping
    public Mono<Map<String, String>> fallbackGet() {
        return Mono.just(Map.of(
                "error", "Service temporarily unavailable",
                "message", "Please try again later"
        ));
    }

    @PostMapping
    public Mono<Map<String, String>> fallbackPost() {
        return fallbackGet();
    }
}
