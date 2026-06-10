Running multiple instances of `grades-service` requires two things: a way to start each instance on a different port, and the api-gateway routing to all instances with load balancing. Here's everything you need.

## 1. Starting multiple instances

Each instance just needs a different port. You never change `application.yml` — override the port at startup with a JVM argument.

**Option A — Maven (development)**
```bash
# Terminal 1
mvn -pl grades-service spring-boot:run -Dspring-boot.run.jvmArguments="-Dserver.port=8082"

# Terminal 2
mvn -pl grades-service spring-boot:run -Dspring-boot.run.jvmArguments="-Dserver.port=8092"

# Terminal 3
mvn -pl grades-service spring-boot:run -Dspring-boot.run.jvmArguments="-Dserver.port=8093"
```

**Option B — JAR (production-like)**
```bash
# Build once
mvn -pl grades-service package -DskipTests

# Then start as many instances as you need
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8082
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8092
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8093
```

---

## 2. Update api-gateway to load balance across all instances

The gateway currently has a single hardcoded URI. Replace it with Spring Cloud Gateway's built-in load balancer using a `lb://` URI. This requires adding the Spring Cloud LoadBalancer dependency and registering each instance.

Since you're on-premises (no Eureka/Consul), the simplest approach is **static instance list** via `application.yml`.

**Add the load balancer dependency to `api-gateway/pom.xml`:**

**Update `api-gateway/application.yml`** — switch grades route to `lb://` and add a static instance list:

Now wire the static instance list into a `LoadBalancerConfig` bean — Spring Cloud LoadBalancer needs to read it:

Enable `@ConfigurationProperties` scanning in the gateway application class:

Validate the build:

Clean. Here's the complete picture:

---

## How it all works

```
Browser / Angular
      │
      ▼
api-gateway :8080
  lb://grades-service  ──round-robin──►  grades-service :8082  (instance 1)
                                    ──►  grades-service :8092  (instance 2)
                                    ──►  grades-service :8093  (instance 3)
```

Each request to `/api/grades/**` is round-robined across whichever instances are listed in the YAML. The gateway circuit breaker still wraps all of them — if an instance goes down, requests to it will trip the breaker and hit `/fallback` instead of hanging.

---

## Startup commands

```bash
# Build once
mvn -pl grades-service package -DskipTests

# Start 3 instances (3 separate terminals)
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8082
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8092
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8093

# Start the gateway (it load balances across all three)
java -jar api-gateway/target/api-gateway-1.0.0-SNAPSHOT.jar
```

---

## Scaling up/down

To add a 4th instance, just add it to `application.yml` and restart the gateway — no code change:

```yaml
loadbalancer:
  instances:
    grades-service:
      - instanceId: grades-1
        uri: http://localhost:8082
      - instanceId: grades-2
        uri: http://localhost:8092
      - instanceId: grades-3
        uri: http://localhost:8093
      - instanceId: grades-4      # ← just add this
        uri: http://localhost:8094
```

To remove an instance, remove its entry and restart the gateway. Since Redis caches the grade data, users won't notice a briefly missing instance — the cache absorbs the gap.