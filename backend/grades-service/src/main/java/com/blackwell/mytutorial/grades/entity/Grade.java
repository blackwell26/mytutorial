package com.blackwell.mytutorial.grades.entity;

import jakarta.persistence.*;
import lombok.*;

/**
 * Maps to public.grades lookup table.
 *
 * DDL:
 *   grade_id     int4 GENERATED ALWAYS AS IDENTITY  (PK)
 *   grade_number int4  NOT NULL UNIQUE
 *   grade_name   varchar(50) NOT NULL
 */
@Entity
@Table(name = "grades", schema = "public")
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder
public class Grade {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "grade_id")
    private Integer gradeId;

    @Column(name = "grade_number", nullable = false, unique = true)
    private Integer gradeNumber;

    @Column(name = "grade_name", nullable = false, length = 50)
    private String gradeName;
}
