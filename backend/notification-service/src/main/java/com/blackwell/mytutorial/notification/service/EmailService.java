package com.blackwell.mytutorial.notification.service;

import jakarta.mail.MessagingException;
import jakarta.mail.internet.MimeMessage;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.mail.javamail.MimeMessageHelper;
import org.springframework.stereotype.Service;
import org.thymeleaf.TemplateEngine;
import org.thymeleaf.context.Context;

@Slf4j
@Service
@RequiredArgsConstructor
public class EmailService {

    private final JavaMailSender mailSender;
    private final TemplateEngine templateEngine;

    @Value("${app.notification.from-email}")
    private String fromEmail;

    @Value("${app.notification.from-name}")
    private String fromName;

    /**
     * Sends a welcome email to a newly registered user.
     *
     * @param toEmail   recipient email address
     * @param username  username for the greeting
     * @param firstName first name if available, otherwise falls back to username
     */
    public void sendWelcomeEmail(String toEmail, String username, String firstName) {
        try {
            // Build Thymeleaf context
            Context ctx = new Context();
            ctx.setVariable("displayName", firstName != null && !firstName.isBlank()
                    ? firstName : username);
            ctx.setVariable("username", username);

            // Render HTML template
            String htmlBody = templateEngine.process("welcome-email", ctx);

            // Build MIME message
            MimeMessage message = mailSender.createMimeMessage();
            MimeMessageHelper helper = new MimeMessageHelper(message, true, "UTF-8");
            helper.setFrom(fromEmail, fromName);
            helper.setTo(toEmail);
            helper.setSubject("Welcome to MyTutorial — you're all set!");
            helper.setText(htmlBody, true);   // true = html

            mailSender.send(message);
            log.info("Welcome email sent to {} (user: {})", toEmail, username);

        } catch (MessagingException | java.io.UnsupportedEncodingException e) {
            // Log and rethrow so the Kafka listener can decide whether to retry
            log.error("Failed to send welcome email to {} (user: {}): {}",
                    toEmail, username, e.getMessage(), e);
            throw new RuntimeException("Email delivery failed for " + toEmail, e);
        }
    }
}
