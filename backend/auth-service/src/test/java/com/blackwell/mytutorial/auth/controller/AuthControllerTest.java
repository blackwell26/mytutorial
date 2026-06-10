package com.blackwell.mytutorial.auth.controller;

import com.blackwell.mytutorial.auth.dto.*;
import com.blackwell.mytutorial.auth.security.JwtTokenProvider;
import com.blackwell.mytutorial.auth.service.AuthService;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.autoconfigure.security.servlet.SecurityAutoConfiguration;
import org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(controllers = AuthController.class, excludeAutoConfiguration = {
        SecurityAutoConfiguration.class,
        UserDetailsServiceAutoConfiguration.class
})
class AuthControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private AuthService authService;

    @MockBean
    private JwtTokenProvider jwtTokenProvider;

    @Test
    void signIn_whenValidRequest_shouldReturnAuthResponse() throws Exception {
        // Arrange
        SignInRequest request = new SignInRequest();
        request.setUsername("testuser");
        request.setPassword("password");

        AuthResponse expectedResponse = AuthResponse.builder()
                .token("mocked-jwt-token")
                .type("Bearer")
                .username("testuser")
                .email("testuser@example.com")
                .roles(List.of("ROLE_USER"))
                .build();

        when(authService.signIn(any(SignInRequest.class))).thenReturn(expectedResponse);

        // Act & Assert
        mockMvc.perform(post("/api/signin")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(objectMapper.writeValueAsString(request)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.token").value("mocked-jwt-token"))
                .andExpect(jsonPath("$.username").value("testuser"))
                .andExpect(jsonPath("$.email").value("testuser@example.com"))
                .andExpect(jsonPath("$.roles[0]").value("ROLE_USER"));

        verify(authService, times(1)).signIn(any(SignInRequest.class));
    }

    @Test
    void signIn_whenInvalidRequest_shouldReturnBadRequest() throws Exception {
        // Arrange
        SignInRequest request = new SignInRequest();
        request.setUsername(""); // Invalid: blank
        request.setPassword("password");

        // Act & Assert
        mockMvc.perform(post("/api/signin")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(objectMapper.writeValueAsString(request)))
                .andExpect(status().isBadRequest());

        verify(authService, never()).signIn(any(SignInRequest.class));
    }

    @Test
    void signUp_whenValidRequest_shouldReturnCreated() throws Exception {
        // Arrange
        SignUpRequest request = new SignUpRequest();
        request.setUsername("newuser");
        request.setEmail("newuser@example.com");
        request.setPassword("password");
        request.setFirstName("John");

        AuthResponse expectedResponse = AuthResponse.builder()
                .token("mocked-jwt-token")
                .type("Bearer")
                .username("newuser")
                .email("newuser@example.com")
                .roles(List.of("student"))
                .build();

        when(authService.signUp(any(SignUpRequest.class))).thenReturn(expectedResponse);

        // Act & Assert
        mockMvc.perform(post("/api/signup")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(objectMapper.writeValueAsString(request)))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.token").value("mocked-jwt-token"))
                .andExpect(jsonPath("$.username").value("newuser"));

        verify(authService, times(1)).signUp(any(SignUpRequest.class));
    }

    @Test
    void signUp_whenUsernameTooShort_shouldReturnBadRequest() throws Exception {
        // Arrange
        SignUpRequest request = new SignUpRequest();
        request.setUsername("ab"); // Invalid: too short (min=3)
        request.setEmail("newuser@example.com");
        request.setPassword("password");

        // Act & Assert
        mockMvc.perform(post("/api/signup")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(objectMapper.writeValueAsString(request)))
                .andExpect(status().isBadRequest());

        verify(authService, never()).signUp(any(SignUpRequest.class));
    }
}
