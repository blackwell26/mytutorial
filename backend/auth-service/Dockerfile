# Build stage
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# Copy parent and all module POMs for dependency resolution
COPY pom.xml ./
COPY eureka-server/pom.xml ./eureka-server/
COPY auth-service/pom.xml ./auth-service/
COPY grades-service/pom.xml ./grades-service/
COPY notification-service/pom.xml ./notification-service/
COPY api-gateway/pom.xml ./api-gateway/

# Resolve dependencies (offline cache)
RUN mvn -B dependency:go-offline -q || true

# Copy all source code
COPY . ./

# Build only the auth-service module and its dependencies
RUN mvn -B clean package -pl auth-service -am -DskipTests -q

# Runtime stage
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

COPY --from=build /app/auth-service/target/*.jar app.jar

EXPOSE 8081

ENTRYPOINT ["java", "-jar", "app.jar"]
