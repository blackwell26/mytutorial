package com.blackwell.mytutorial.grades.service;

import com.blackwell.mytutorial.grades.dto.GradeResponse;
import com.blackwell.mytutorial.grades.entity.Grade;
import com.blackwell.mytutorial.grades.repository.GradeRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.stream.Collectors;

@Slf4j
@Service
@RequiredArgsConstructor
public class GradeService {

    private final GradeRepository gradeRepository;

    /**
     * Returns all grade lookup entries.
     * Cache key: "grades::all"
     */
    @Cacheable(cacheNames = "grades", key = "'all'")
    @Transactional(readOnly = true)
    public List<GradeResponse> getAllGrades() {
        log.debug("Fetching all grades from DB");
        return gradeRepository.findAll().stream()
                .map(this::toResponse)
                .collect(Collectors.toList());
    }

    /**
     * Returns a single grade by its grade_number.
     * Cache key: "grades::number:<gradeNumber>"
     */
    @Cacheable(cacheNames = "grades", key = "'number:' + #gradeNumber")
    @Transactional(readOnly = true)
    public GradeResponse getGradeByNumber(Integer gradeNumber) {
        log.debug("Fetching grade for gradeNumber={}", gradeNumber);
        return gradeRepository.findByGradeNumber(gradeNumber)
                .map(this::toResponse)
                .orElseThrow(() -> new IllegalArgumentException(
                        "Grade not found for grade_number: " + gradeNumber));
    }

    private GradeResponse toResponse(Grade g) {
        return GradeResponse.builder()
                .gradeId(g.getGradeId())
                .gradeNumber(g.getGradeNumber())
                .gradeName(g.getGradeName())
                .build();
    }
}
