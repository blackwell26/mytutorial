package com.blackwell.mytutorial.auth.service;

import com.blackwell.mytutorial.auth.dto.*;
import com.blackwell.mytutorial.auth.entity.*;
import com.blackwell.mytutorial.auth.kafka.AuthEventProducer;
import com.blackwell.mytutorial.auth.repository.RoleRepository;
import com.blackwell.mytutorial.auth.repository.UserRepository;
import com.blackwell.mytutorial.auth.security.JwtTokenProvider;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.core.ValueOperations;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.Collections;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class AuthServiceTest {

    @Mock
    private AuthenticationManager authenticationManager;
    @Mock
    private JwtTokenProvider jwtTokenProvider;
    @Mock
    private UserRepository userRepository;
    @Mock
    private RoleRepository roleRepository;
    @Mock
    private PasswordEncoder passwordEncoder;
    @Mock
    private AuthEventProducer eventProducer;
    @Mock
    private RedisTemplate<String, Object> redisTemplate;
    @Mock
    private ValueOperations<String, Object> valueOperations;

    @InjectMocks
    private AuthService authService;

    @BeforeEach
    void setUp() {
        ReflectionTestUtils.setField(authService, "defaultRoleId", 3);
    }

    @Test
    void signIn_whenValidCredentials_shouldReturnAuthResponse() {
        // Arrange
        SignInRequest request = new SignInRequest();
        request.setUsername("testuser");
        request.setPassword("password");

        Authentication authentication = mock(Authentication.class);
        UserDetails userDetails = mock(UserDetails.class);
        User user = User.builder()
                .username("testuser")
                .email("testuser@example.com")
                .build();

        doReturn(valueOperations).when(redisTemplate).opsForValue();
        when(authenticationManager.authenticate(any(UsernamePasswordAuthenticationToken.class))).thenReturn(authentication);
        when(jwtTokenProvider.generateToken(authentication)).thenReturn("mockedToken");
        when(authentication.getPrincipal()).thenReturn(userDetails);
        doReturn(List.of(new SimpleGrantedAuthority("ROLE_USER"))).when(userDetails).getAuthorities();
        when(userRepository.findByUsername("testuser")).thenReturn(Optional.of(user));

        // Act
        AuthResponse response = authService.signIn(request);

        // Assert
        assertThat(response).isNotNull();
        assertThat(response.getToken()).isEqualTo("mockedToken");
        assertThat(response.getUsername()).isEqualTo("testuser");
        assertThat(response.getEmail()).isEqualTo("testuser@example.com");
        assertThat(response.getRoles()).containsExactly("ROLE_USER");

        verify(valueOperations, times(1)).set(eq("auth:token:testuser"), eq("mockedToken"), eq(24L), eq(TimeUnit.HOURS));
        verify(eventProducer, times(1)).publishSignInEvent("testuser");
    }

    @Test
    void signUp_whenUsernameTaken_shouldThrowException() {
        // Arrange
        SignUpRequest request = new SignUpRequest();
        request.setUsername("takenuser");
        request.setEmail("new@example.com");

        when(userRepository.existsByUsername("takenuser")).thenReturn(true);

        // Act & Assert
        assertThatThrownBy(() -> authService.signUp(request))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("Username is already taken");

        verify(userRepository, never()).save(any(User.class));
    }

    @Test
    void signUp_whenEmailTaken_shouldThrowException() {
        // Arrange
        SignUpRequest request = new SignUpRequest();
        request.setUsername("newuser");
        request.setEmail("taken@example.com");

        when(userRepository.existsByUsername("newuser")).thenReturn(false);
        when(userRepository.existsByEmail("taken@example.com")).thenReturn(true);

        // Act & Assert
        assertThatThrownBy(() -> authService.signUp(request))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("Email is already registered");

        verify(userRepository, never()).save(any(User.class));
    }

    @Test
    void signUp_whenSuccessful_shouldRegisterAndSignIn() {
        // Arrange
        SignUpRequest request = new SignUpRequest();
        request.setUsername("newuser");
        request.setEmail("new@example.com");
        request.setPassword("password");
        request.setFirstName("John");

        Role role = Role.builder().roleId(3).roleName("student").build();
        when(userRepository.existsByUsername("newuser")).thenReturn(false);
        when(userRepository.existsByEmail("new@example.com")).thenReturn(false);
        when(roleRepository.findById(3)).thenReturn(Optional.of(role));
        when(passwordEncoder.encode("password")).thenReturn("hashedPassword");

        // Mock nested signIn call
        Authentication authentication = mock(Authentication.class);
        UserDetails userDetails = mock(UserDetails.class);
        doReturn(valueOperations).when(redisTemplate).opsForValue();
        when(authenticationManager.authenticate(any(UsernamePasswordAuthenticationToken.class))).thenReturn(authentication);
        when(jwtTokenProvider.generateToken(authentication)).thenReturn("mockedToken");
        when(authentication.getPrincipal()).thenReturn(userDetails);
        doReturn(List.of(new SimpleGrantedAuthority("student"))).when(userDetails).getAuthorities();
        when(userRepository.findByUsername("newuser")).thenReturn(Optional.of(User.builder().username("newuser").email("new@example.com").build()));

        // Act
        AuthResponse response = authService.signUp(request);

        // Assert
        assertThat(response).isNotNull();
        assertThat(response.getToken()).isEqualTo("mockedToken");
        assertThat(response.getUsername()).isEqualTo("newuser");
        verify(userRepository, times(1)).save(any(User.class));
        verify(eventProducer, times(1)).publishSignUpEvent("newuser", "new@example.com", "John");
    }
}
