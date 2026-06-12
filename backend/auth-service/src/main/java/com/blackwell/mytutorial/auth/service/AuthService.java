package com.blackwell.mytutorial.auth.service;

import com.blackwell.mytutorial.auth.dto.*;
import com.blackwell.mytutorial.auth.entity.*;
import com.blackwell.mytutorial.auth.kafka.AuthEventProducer;
import com.blackwell.mytutorial.auth.repository.RoleRepository;
import com.blackwell.mytutorial.auth.repository.UserRepository;
import com.blackwell.mytutorial.auth.security.JwtTokenProvider;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cache.annotation.CacheEvict;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.security.authentication.*;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

@Slf4j
@Service
@RequiredArgsConstructor
public class AuthService {

    private final AuthenticationManager authenticationManager;
    private final JwtTokenProvider jwtTokenProvider;
    private final UserRepository userRepository;
    private final RoleRepository roleRepository;
    private final PasswordEncoder passwordEncoder;
    private final AuthEventProducer eventProducer;
    private final RedisTemplate<String, Object> redisTemplate;

    /** Default role assigned to every new user — configured in application.yml */
    @Value("${app.signup.default-role-id:3}")
    private int defaultRoleId;

    private static final String TOKEN_CACHE_PREFIX = "auth:token:";

    @Transactional(readOnly = true)
    public AuthResponse signIn(SignInRequest request) {
        Authentication authentication = authenticationManager.authenticate(
                new UsernamePasswordAuthenticationToken(
                        request.getUsername(), request.getPassword()));

        String token = jwtTokenProvider.generateToken(authentication);

        // Cache token reference in Redis (for fast invalidation later)
        redisTemplate.opsForValue().set(
                TOKEN_CACHE_PREFIX + request.getUsername(),
                token,
                24, TimeUnit.HOURS
        );

        var userDetails = (org.springframework.security.core.userdetails.UserDetails)
                authentication.getPrincipal();

        List<String> roles = userDetails.getAuthorities().stream()
                .map(GrantedAuthority::getAuthority)
                .collect(Collectors.toList());

        // Fetch email from DB for response
        String email = userRepository.findByUsername(request.getUsername())
                .map(User::getEmail)
                .orElse("");

        eventProducer.publishSignInEvent(request.getUsername());

        return AuthResponse.builder()
                .token(token)
                .type("Bearer")
                .username(request.getUsername())
                .email(email)
                .roles(roles)
                .build();
    }

    @Transactional
    @CacheEvict(cacheNames = {"users", "users-email"}, allEntries = true)
    public AuthResponse signUp(SignUpRequest request) {
        log.info("signUp() attempting to register user: {}", request.getUsername());

        if (userRepository.existsByUsername(request.getUsername())) {
            throw new IllegalArgumentException("Username is already taken");
        }
        if (userRepository.existsByEmail(request.getEmail())) {
            throw new IllegalArgumentException("Email is already registered");
        }

        // Fetch the existing 'student' role from DB (role_id=3, role_name='student').
        // We never construct Role manually — the row already exists and has an
        // IDENTITY PK, so building a new instance would cause a constraint violation.
        Role studentRole = roleRepository.findById(defaultRoleId)
                .orElseThrow(() -> new IllegalStateException(
                        "Default role not found in user_roles table (role_id=" + defaultRoleId + "). "
                        + "Ensure the role exists before registering users."));

        log.debug("Assigning default role '{}' (id={}) to new user '{}'",
                studentRole.getRoleName(), studentRole.getRoleId(), request.getUsername());

        User user = User.builder()
                .username(request.getUsername())
                .email(request.getEmail())
                .passwordHash(passwordEncoder.encode(request.getPassword()))
                .mustChangePassword(0)
                .isActive(true)
                .roles(Set.of(studentRole))
                .build();

        userRepository.save(user);

        log.info("User registered successfully: {} with role '{}'",
                request.getUsername(), studentRole.getRoleName());

        // Publish event with email so notification-service can send the welcome email
        eventProducer.publishSignUpEvent(
                request.getUsername(),
                request.getEmail(),
                request.getFirstName()   // may be null — producer falls back to username
        );

        // Auto sign-in after registration
        SignInRequest signIn = new SignInRequest();
        signIn.setUsername(request.getUsername());
        signIn.setPassword(request.getPassword());
        return signIn(signIn);
    }
}
