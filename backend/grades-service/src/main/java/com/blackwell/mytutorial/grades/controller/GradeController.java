package com.blackwell.mytutorial.grades.controller;

import com.blackwell.mytutorial.grades.dto.GradeResponse;
import com.blackwell.mytutorial.grades.service.GradeService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.Map;

@Slf4j
@RestController
@RequiredArgsConstructor
public class GradeController {

    private final GradeService gradeService;

    /**
     * GET /api/grades
     * Returns the full grade lookup list (cached).
     */
    @GetMapping("/api/grades")
    public ResponseEntity<List<GradeResponse>> getAllGrades() {
        log.info("################ GradeController@getAllGrades");
        
        List<GradeResponse> grades = gradeService.getAllGrades();
        log.info("Fetched {} grades, {} ", grades.size(), grades.stream().toList());
        return ResponseEntity.ok(grades);
        //return ResponseEntity.ok(gradeService.getAllGrades());
    }

    /**
     * GET /api/grades/{gradeNumber}
     * Returns a single grade by its grade_number (cached).
     */
    @GetMapping("/api/grades/{gradeNumber}")
    public ResponseEntity<GradeResponse> getGradeByNumber(@PathVariable Integer gradeNumber) {
        return ResponseEntity.ok(gradeService.getGradeByNumber(gradeNumber));
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<Map<String, String>> handleNotFound(IllegalArgumentException ex) {
        return ResponseEntity.status(404)
                .body(Map.of("error", ex.getMessage()));
    }
}
