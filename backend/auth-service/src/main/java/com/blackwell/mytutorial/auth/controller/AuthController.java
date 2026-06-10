package com.blackwell.mytutorial.auth.controller;

import com.blackwell.mytutorial.auth.dto.*;
import com.blackwell.mytutorial.auth.service.AuthService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@Slf4j
@RestController
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;

    /**
     * POST /api/signin
     * Authenticates credentials and returns a JWT.
     */
    @PostMapping("/api/signin")
    public ResponseEntity<AuthResponse> signIn(@Valid @RequestBody SignInRequest request) {
        log.info("Sign-in attempt for user: {}", request.getUsername());
        AuthResponse response = authService.signIn(request);
        return ResponseEntity.ok(response);
    }

    /**
     * POST /api/signup
     * Registers a new user and returns a JWT (auto-signed-in).
     */
    @PostMapping("/api/signup")
    public ResponseEntity<AuthResponse> signUp(@Valid @RequestBody SignUpRequest request) {
        log.info("Sign-up attempt for user: {}", request.getUsername());
        AuthResponse response = authService.signUp(request);
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    /**
     * Global validation error handler for this controller.
     */
    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, String>> handleBadRequest(IllegalArgumentException ex) {
        return ResponseEntity.badRequest()
                .body(Map.of("error", ex.getMessage()));
    }
}
