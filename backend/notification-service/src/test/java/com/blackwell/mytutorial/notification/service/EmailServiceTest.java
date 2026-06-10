package com.blackwell.mytutorial.notification.service;

import jakarta.mail.internet.MimeMessage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mail.javamail.JavaMailSender;
import org.thymeleaf.TemplateEngine;
import org.thymeleaf.context.Context;
import org.springframework.test.util.ReflectionTestUtils;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class EmailServiceTest {

    @Mock
    private JavaMailSender mailSender;

    @Mock
    private TemplateEngine templateEngine;

    @InjectMocks
    private EmailService emailService;

    @BeforeEach
    void setUp() {
        ReflectionTestUtils.setField(emailService, "fromEmail", "noreply@example.com");
        ReflectionTestUtils.setField(emailService, "fromName", "MyTutorial Support");
    }

    @Test
    void sendWelcomeEmail_whenSuccessful_shouldSendMail() throws Exception {
        // Arrange
        MimeMessage mimeMessage = mock(MimeMessage.class);
        when(mailSender.createMimeMessage()).thenReturn(mimeMessage);
        when(templateEngine.process(eq("welcome-email"), any(Context.class))).thenReturn("<html>Welcome!</html>");

        // Act
        emailService.sendWelcomeEmail("recipient@example.com", "testuser", "John");

        // Assert
        verify(templateEngine, times(1)).process(eq("welcome-email"), any(Context.class));
        verify(mailSender, times(1)).send(mimeMessage);
    }

    @Test
    void sendWelcomeEmail_whenMailSenderThrowsException_shouldThrowRuntimeException() throws Exception {
        // Arrange
        MimeMessage mimeMessage = mock(MimeMessage.class);
        when(mailSender.createMimeMessage()).thenReturn(mimeMessage);
        when(templateEngine.process(eq("welcome-email"), any(Context.class))).thenReturn("<html>Welcome!</html>");
        doThrow(new jakarta.mail.MessagingException("Mail server down")).when(mimeMessage).setFrom(any(jakarta.mail.Address.class));

        // Act & Assert
        assertThatThrownBy(() -> emailService.sendWelcomeEmail("recipient@example.com", "testuser", "John"))
                .isInstanceOf(RuntimeException.class)
                .hasMessageContaining("Email delivery failed for recipient@example.com");

        verify(mailSender, never()).send(mimeMessage);
    }
}
