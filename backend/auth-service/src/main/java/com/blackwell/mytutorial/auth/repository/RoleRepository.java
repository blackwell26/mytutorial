package com.blackwell.mytutorial.auth.repository;

import com.blackwell.mytutorial.auth.entity.Role;
import org.springframework.cache.annotation.Cacheable;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Optional;

public interface RoleRepository extends JpaRepository<Role, Integer> {

    @Cacheable(cacheNames = "roles", key = "#roleName", unless = "#result == null")
    Optional<Role> findByRoleName(String roleName);
}
