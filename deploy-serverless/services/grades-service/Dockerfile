# Dockerfile for grades-service — Lambda Web Adapter
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

COPY backend/pom.xml ./
COPY backend/eureka-server/pom.xml ./eureka-server/
COPY backend/auth-service/pom.xml ./auth-service/
COPY backend/grades-service/pom.xml ./grades-service/
COPY backend/notification-service/pom.xml ./notification-service/
COPY backend/api-gateway/pom.xml ./api-gateway/

RUN mvn dependency:go-offline -q

COPY backend/ .

RUN mvn -B clean package -pl grades-service -am -DskipTests -q

FROM public.ecr.aws/aws-greengrass/blipp/temurin:21-jre-21.0.6_7-jre-headless

COPY --from=build /app/grades-service/target/*.jar /app.jar

ENV PORT=8080
ENV SPRING_PROFILES_ACTIVE=serverless

ENTRYPOINT ["java", "-jar", "/app.jar"]
