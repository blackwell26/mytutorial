package com.blackwell.mytutorial.grades;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cache.annotation.EnableCaching;

@SpringBootApplication
@EnableCaching
public class GradesServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(GradesServiceApplication.class, args);
    }
}
