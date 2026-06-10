package com.blackwell.mytutorial.auth.entity;

import jakarta.persistence.*;
import lombok.*;

import java.time.LocalDateTime;

/**
 * Maps to public.user_roles table.
 *
 * DDL:
 *   role_id   int4 GENERATED ALWAYS AS IDENTITY  (PK)
 *   role_name varchar(50) NOT NULL UNIQUE
 *   description varchar(255) NULL
 *   created_at  timestamp DEFAULT CURRENT_TIMESTAMP NULL
 */
@Entity
@Table(name = "user_roles", schema = "public")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Role {

    @Id
    //@GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "role_id")
    private Integer roleId;

    @Column(name = "role_name", nullable = false, unique = true, length = 50)
    private String roleName;  // e.g. "ROLE_USER", "ROLE_ADMIN"

    @Column(name = "description", length = 255)
    private String description;

    @Column(name = "created_at", insertable = false, updatable = false)
    private LocalDateTime createdAt;
}
