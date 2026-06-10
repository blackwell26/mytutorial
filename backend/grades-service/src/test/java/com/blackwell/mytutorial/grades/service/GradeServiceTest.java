package com.blackwell.mytutorial.grades.service;

import com.blackwell.mytutorial.grades.dto.GradeResponse;
import com.blackwell.mytutorial.grades.entity.Grade;
import com.blackwell.mytutorial.grades.repository.GradeRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.Arrays;
import java.util.List;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class GradeServiceTest {

    @Mock
    private GradeRepository gradeRepository;

    @InjectMocks
    private GradeService gradeService;

    private Grade grade1;
    private Grade grade2;

    @BeforeEach
    void setUp() {
        grade1 = Grade.builder()
                .gradeId(1)
                .gradeNumber(10)
                .gradeName("A")
                .build();
        grade2 = Grade.builder()
                .gradeId(2)
                .gradeNumber(11)
                .gradeName("B")
                .build();
    }

    @Test
    void getAllGrades_shouldReturnMappedResponses() {
        // Arrange
        when(gradeRepository.findAll()).thenReturn(Arrays.asList(grade1, grade2));

        // Act
        List<GradeResponse> result = gradeService.getAllGrades();

        // Assert
        assertThat(result).hasSize(2);
        assertThat(result.get(0).getGradeId()).isEqualTo(1);
        assertThat(result.get(0).getGradeNumber()).isEqualTo(10);
        assertThat(result.get(0).getGradeName()).isEqualTo("A");
        assertThat(result.get(1).getGradeId()).isEqualTo(2);
        assertThat(result.get(1).getGradeNumber()).isEqualTo(11);
        assertThat(result.get(1).getGradeName()).isEqualTo("B");
        verify(gradeRepository, times(1)).findAll();
    }

    @Test
    void getGradeByNumber_whenFound_shouldReturnMappedResponse() {
        // Arrange
        when(gradeRepository.findByGradeNumber(10)).thenReturn(Optional.of(grade1));

        // Act
        GradeResponse result = gradeService.getGradeByNumber(10);

        // Assert
        assertThat(result).isNotNull();
        assertThat(result.getGradeId()).isEqualTo(1);
        assertThat(result.getGradeNumber()).isEqualTo(10);
        assertThat(result.getGradeName()).isEqualTo("A");
        verify(gradeRepository, times(1)).findByGradeNumber(10);
    }

    @Test
    void getGradeByNumber_whenNotFound_shouldThrowException() {
        // Arrange
        when(gradeRepository.findByGradeNumber(99)).thenReturn(Optional.empty());

        // Act & Assert
        assertThatThrownBy(() -> gradeService.getGradeByNumber(99))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Grade not found for grade_number: 99");
        verify(gradeRepository, times(1)).findByGradeNumber(99);
    }
}
