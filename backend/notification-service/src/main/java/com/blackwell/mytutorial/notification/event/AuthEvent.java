package com.blackwell.mytutorial.notification.event;

import lombok.Data;
import lombok.NoArgsConstructor;

/**
 * Represents the auth-events Kafka payload published by auth-service.
 *
 * Fields intentionally match the Map keys produced by AuthEventProducer:
 *   event, username, email, firstName, timestamp
 */
@Data
@NoArgsConstructor
public class AuthEvent {

    /** Event type discriminator — e.g. "USER_REGISTERED", "USER_SIGNED_IN" */
    private String event;

    private String username;

    /** Present only on USER_REGISTERED events */
    private String email;

    /** Present only on USER_REGISTERED events */
    private String firstName;

    private String timestamp;
}
