package com.blackwell.mytutorial.auth.entity;

import jakarta.persistence.*;
import lombok.*;

import java.time.LocalDateTime;
import java.util.Set;

/**
 * Maps to public.users table.
 *
 * DDL:
 *   user_id               int4 GENERATED ALWAYS AS IDENTITY  (PK)
 *   username              varchar(50)  NOT NULL UNIQUE
 *   email                 varchar(255) NOT NULL UNIQUE
 *   password_hash         varchar(255) NOT NULL
 *   first_name            varchar(100) NULL
 *   last_name             varchar(100) NULL
 *   created_at            timestamp    DEFAULT CURRENT_TIMESTAMP NULL
 *   last_login            timestamp    NULL
 *   is_active             bool         DEFAULT true NULL
 *   temp_password_hash    varchar(255) NULL
 *   temp_password_expiry  timestamp    NULL
 *   must_change_password  int4         NOT NULL
 *
 * Roles linked via public.user_role_mapping:
 *   user_role_mapping.user_id → users.user_id
 *   user_role_mapping.role_id → user_roles.role_id
 */
@Entity
@Table(name = "users", schema = "public")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "user_id")
    private Integer userId;

    @Column(name = "username", nullable = false, unique = true, length = 50)
    private String username;

    @Column(name = "email", nullable = false, unique = true, length = 255)
    private String email;

    /** Stores the BCrypt hash — mapped to password_hash column. */
    @Column(name = "password_hash", nullable = false, length = 255)
    private String passwordHash;

    @Column(name = "first_name", length = 100)
    private String firstName;

    @Column(name = "last_name", length = 100)
    private String lastName;

    @Column(name = "created_at", insertable = false, updatable = false)
    private LocalDateTime createdAt;

    @Column(name = "last_login")
    private LocalDateTime lastLogin;

    @Builder.Default
    @Column(name = "is_active")
    private Boolean isActive = true;

    @Column(name = "temp_password_hash", length = 255)
    private String tempPasswordHash;

    @Column(name = "temp_password_expiry")
    private LocalDateTime tempPasswordExpiry;

    /** 0 = not required, 1 = must change on next login. */
    @Column(name = "must_change_password", nullable = false)
    private Integer mustChangePassword;

    @ManyToMany(fetch = FetchType.EAGER)
    @JoinTable(
        name = "user_role_mapping",
        schema = "public",
        joinColumns = @JoinColumn(name = "user_id"),
        inverseJoinColumns = @JoinColumn(name = "role_id")
    )
    private Set<Role> roles;
}
