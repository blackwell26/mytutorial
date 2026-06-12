package com.blackwell.mytutorial.auth.repository;

import com.blackwell.mytutorial.auth.entity.User;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface UserRepository extends JpaRepository<User, Integer> {

    @Cacheable(cacheNames = "users", key = "#username", unless = "#result == null")
    Optional<User> findByUsername(String username);

    @Cacheable(cacheNames = "users-email", key = "#email", unless = "#result == null")
    Optional<User> findByEmail(String email);

    boolean existsByUsername(String username);

    boolean existsByEmail(String email);
}
