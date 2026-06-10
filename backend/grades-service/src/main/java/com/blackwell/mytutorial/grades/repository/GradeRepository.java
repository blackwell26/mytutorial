package com.blackwell.mytutorial.grades.repository;

import com.blackwell.mytutorial.grades.entity.Grade;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface GradeRepository extends JpaRepository<Grade, Integer> {

    Optional<Grade> findByGradeNumber(Integer gradeNumber);

    Optional<Grade> findByGradeName(String gradeName);
}
