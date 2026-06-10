package com.blackwell.mytutorial.grades.controller;

import com.blackwell.mytutorial.grades.dto.GradeResponse;
import com.blackwell.mytutorial.grades.security.JwtTokenProvider;
import com.blackwell.mytutorial.grades.service.GradeService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.web.servlet.MockMvc;

import java.util.Arrays;

import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(GradeController.class)
class GradeControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private GradeService gradeService;

    @MockBean
    private JwtTokenProvider jwtTokenProvider;

    @Test
    @WithMockUser(username = "testuser")
    void getAllGrades_shouldReturnGradesList() throws Exception {
        // Arrange
        GradeResponse grade1 = GradeResponse.builder()
                .gradeId(1)
                .gradeNumber(10)
                .gradeName("A")
                .build();
        GradeResponse grade2 = GradeResponse.builder()
                .gradeId(2)
                .gradeNumber(11)
                .gradeName("B")
                .build();
        when(gradeService.getAllGrades()).thenReturn(Arrays.asList(grade1, grade2));

        // Act & Assert
        mockMvc.perform(get("/api/grades"))
                .andExpect(status().isOk())
                .andExpect(content().contentType(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$[0].gradeId").value(1))
                .andExpect(jsonPath("$[0].gradeNumber").value(10))
                .andExpect(jsonPath("$[0].gradeName").value("A"))
                .andExpect(jsonPath("$[1].gradeId").value(2))
                .andExpect(jsonPath("$[1].gradeNumber").value(11))
                .andExpect(jsonPath("$[1].gradeName").value("B"));

        verify(gradeService, times(1)).getAllGrades();
    }

    @Test
    @WithMockUser(username = "testuser")
    void getGradeByNumber_whenFound_shouldReturnGrade() throws Exception {
        // Arrange
        GradeResponse grade = GradeResponse.builder()
                .gradeId(1)
                .gradeNumber(10)
                .gradeName("A")
                .build();
        when(gradeService.getGradeByNumber(10)).thenReturn(grade);

        // Act & Assert
        mockMvc.perform(get("/api/grades/10"))
                .andExpect(status().isOk())
                .andExpect(content().contentType(MediaType.APPLICATION_JSON))
                .andExpect(jsonPath("$.gradeId").value(1))
                .andExpect(jsonPath("$.gradeNumber").value(10))
                .andExpect(jsonPath("$.gradeName").value("A"));

        verify(gradeService, times(1)).getGradeByNumber(10);
    }

    @Test
    @WithMockUser(username = "testuser")
    void getGradeByNumber_whenNotFound_shouldReturn404() throws Exception {
        // Arrange
        when(gradeService.getGradeByNumber(99)).thenThrow(new IllegalArgumentException("Grade not found for grade_number: 99"));

        // Act & Assert
        mockMvc.perform(get("/api/grades/99"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error").value("Grade not found for grade_number: 99"));

        verify(gradeService, times(1)).getGradeByNumber(99);
    }

    @Test
    void getAllGrades_withoutAuth_shouldReturn401() throws Exception {
        mockMvc.perform(get("/api/grades"))
                .andExpect(status().isUnauthorized());
    }
}
