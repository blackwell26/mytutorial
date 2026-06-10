package com.blackwell.mytutorial.grades.dto;

import lombok.*;

import java.io.Serializable;

/**
 * DTO returned in API responses. Serializable so Redis can cache it.
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class GradeResponse implements Serializable {
    private Integer gradeId;
    private Integer gradeNumber;
    private String gradeName;
}
