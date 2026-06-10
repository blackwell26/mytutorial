package com.blackwell.mytutorial.auth.kafka;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

/**
 * Publishes authentication lifecycle events to the 'auth-events' Kafka topic.
 *
 * Consumers (e.g. notification-service) subscribe to this topic to react
 * asynchronously — no direct coupling between services.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class AuthEventProducer {

    private final KafkaTemplate<String, Object> kafkaTemplate;

    @Value("${app.kafka.topic.auth-events}")
    private String authEventsTopic;

    public void publishSignInEvent(String username) {
        Map<String, Object> event = new HashMap<>();
        event.put("event",     "USER_SIGNED_IN");
        event.put("username",  username);
        event.put("timestamp", Instant.now().toString());

        send(username, event);
    }

    /**
     * Publishes a USER_REGISTERED event.
     * Includes email so downstream consumers (e.g. notification-service)
     * can send a welcome email without querying the DB themselves.
     *
     * @param username  registered username (used as Kafka partition key)
     * @param email     user's email address for the welcome notification
     * @param firstName optional first name for personalised greeting
     */
    public void publishSignUpEvent(String username, String email, String firstName) {
        Map<String, Object> event = new HashMap<>();
        event.put("event",     "USER_REGISTERED");
        event.put("username",  username);
        event.put("email",     email);
        event.put("firstName", firstName != null ? firstName : username);
        event.put("timestamp", Instant.now().toString());

        send(username, event);
    }

    private void send(String key, Map<String, Object> event) {
        kafkaTemplate.send(authEventsTopic, key, event)
                .whenComplete((result, ex) -> {
                    if (ex != null) {
                        log.error("Failed to publish event '{}' for key '{}': {}",
                                event.get("event"), key, ex.getMessage());
                    } else {
                        log.debug("Event '{}' published for '{}' → partition {}",
                                event.get("event"), key,
                                result.getRecordMetadata().partition());
                    }
                });
    }
}
