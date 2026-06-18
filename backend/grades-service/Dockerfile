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

# Build only the grades-service module and its dependencies
RUN mvn -B clean package -pl grades-service -am -DskipTests -q

# Runtime stage
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app

# Install curl for downloading the OTel agent
RUN apk add --no-cache curl

# Download OpenTelemetry Java agent
RUN curl -sL -o /app/opentelemetry-javaagent.jar \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.10.0/opentelemetry-javaagent.jar

COPY --from=build /app/grades-service/target/*.jar app.jar

EXPOSE 8082

ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-jar", "app.jar"]
