package com.blackwell.mytutorial.notification.kafka;

import com.blackwell.mytutorial.notification.event.AuthEvent;
import com.blackwell.mytutorial.notification.service.EmailService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.kafka.support.Acknowledgment;
import org.springframework.kafka.support.KafkaHeaders;
import org.springframework.messaging.handler.annotation.Header;
import org.springframework.messaging.handler.annotation.Payload;
import org.springframework.stereotype.Component;

/**
 * Consumes auth lifecycle events from the 'auth-events' Kafka topic.
 *
 * Flow:
 *   auth-service  ──[Kafka]──►  AuthEventConsumer  ──►  EmailService  ──►  SMTP
 *
 * Manual acknowledgement ensures the offset is only committed after the email
 * is successfully sent. If email delivery fails, the message is not committed
 * and will be redelivered on the next poll.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class AuthEventConsumer {

    private final EmailService emailService;

    @Value("${app.kafka.topic.auth-events}")
    private String authEventsTopic;

    @KafkaListener(
        topics           = "${app.kafka.topic.auth-events}",
        groupId          = "${spring.kafka.consumer.group-id}",
        containerFactory = "authEventKafkaListenerContainerFactory"
    )
    public void consume(
            @Payload AuthEvent event,
            @Header(KafkaHeaders.RECEIVED_TOPIC)     String topic,
            @Header(KafkaHeaders.RECEIVED_PARTITION) int partition,
            @Header(KafkaHeaders.OFFSET)             long offset,
            Acknowledgment ack) {

        log.debug("Received event '{}' from topic={} partition={} offset={}",
                event.getEvent(), topic, partition, offset);

        try {
            if ("USER_REGISTERED".equals(event.getEvent())) {
                handleUserRegistered(event);
            }
            // Additional event types (USER_SIGNED_IN, etc.) can be handled here

            // Commit offset only after successful processing
            ack.acknowledge();

        } catch (Exception ex) {
            log.error("Error processing auth event '{}' for user '{}': {}",
                    event.getEvent(), event.getUsername(), ex.getMessage(), ex);
            // Do NOT acknowledge — Kafka will redeliver based on auto-offset-reset policy
        }
    }

    private void handleUserRegistered(AuthEvent event) {
        if (event.getEmail() == null || event.getEmail().isBlank()) {
            log.warn("USER_REGISTERED event for '{}' has no email address — skipping notification",
                    event.getUsername());
            return;
        }

        log.info("Sending welcome email to {} for new user '{}'",
                event.getEmail(), event.getUsername());

        emailService.sendWelcomeEmail(
                event.getEmail(),
                event.getUsername(),
                event.getFirstName()
        );
    }
}
