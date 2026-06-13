# MyTutorial — Agent Guide

Full-stack microservices e-commerce tutorial app. Spring Boot 3.2.5 (Java 17+) backend + Angular 21 standalone frontend.

## Quick Commands

### Backend (Maven multi-module, Java 17)

```bash
cd backend

# Build all modules (skip tests)
mvn clean package -DskipTests

# Build all modules (with tests — needs Postgres+Redis running)
mvn clean package

# Build a single module
mvn clean package -pl auth-service -am

# Run tests for one module
mvn test -pl auth-service

# Run a specific test class
mvn test -pl auth-service -Dtest=AuthServiceTest

# Run app locally (needs Postgres, Redis, Kafka on localhost:5434/6379/9092)
mvn spring-boot:run -pl auth-service

# Run with Docker profile
mvn spring-boot:run -pl auth-service -Dspring-boot.run.profiles=docker
```

### Frontend (Angular 21, zoneless, vitest)

```bash
cd frontend

npm install          # Install deps
npx ng serve         # Dev server on http://localhost:4200
npx ng build         # Production build
npx vitest run       # Run tests (vitest, not Jasmine/Karma)
npx vitest --watch   # Watch mode
npx prettier --check "src/**/*.{ts,html,scss,css,json}"   # Format check
npx prettier --write "src/**/*.{ts,html,scss,css,json}"   # Format fix
```

### Full Stack (Docker Compose)

```bash
docker compose up -d                  # Start everything (infra + services + monitoring)
docker compose up -d auth-service     # Single service
docker compose logs -f auth-service   # Follow logs
```

### Deployment

| Target | Build | Deploy |
|--------|-------|--------|
| **Minikube** | `deploy-local/scripts/build-all.sh` | `deploy-local/scripts/deploy-local.sh dev` |
| **K8s** | `REGISTRY=myreg.io k8s/scripts/build-and-push.sh` | `k8s/scripts/deploy.sh dev` |
| **OpenShift** | `deploy-openshift/scripts/build-openshift.sh` | `deploy-openshift/scripts/deploy-openshift.sh dev` |

Quick rebuild of one service: `deploy-local/scripts/rebuild-service.sh auth-service`
Full reset: `deploy-local/scripts/reset-local.sh` (deletes minikube, recreates)

## Architecture

### Backend — 5 microservices

```
api-gateway (8080) ─┬──→ auth-service (8081)
                     ├──→ grades-service (8082)
                     └──→ notification-service (8083)
                              ↓
                          [Kafka consumer only, no REST]
```

| Service | Port | Role | Depends on |
|---------|------|------|------------|
| **eureka-server** | 8761 | Service Discovery (Eureka) | — |
| **api-gateway** | 8080 | Spring Cloud Gateway, JWT validation | Redis, Eureka |
| **auth-service** | 8081 | Auth (sign-up/sign-in), JWT generation | Postgres, Redis, Kafka, Eureka |
| **grades-service** | 8082 | Grade CRUD, Redis caching | Postgres, Redis, Eureka |
| **notification-service** | 8083 | Email from Kafka events | Kafka, Eureka |

**Communication patterns:**
- Synchronous: Gateway → Services via service discovery (Eureka + load-balanced)
- Asynchronous: auth-service → Kafka → notification-service (auth events)
- Inter-service: Gateway injects `X-Authenticated-User` header after JWT validation

### Frontend — Angular 21 standalone

```
app.ts (root, standalone, <router-outlet/>)
├── Guards: auth.guard.ts (functional CanActivateFn)
├── Interceptors: jwt.interceptor.ts (functional HttpInterceptorFn)
├── Services: auth.service.ts, grade.service.ts
├── Models: auth.model.ts, grade.model.ts
└── Pages (lazy-loaded):
    ├── auth/ — Sign-in / Sign-up (ReactiveForms, Signals)
    ├── dashboard/ — Protected shell with child routes
    └── grades/ — Grade list (Signals, error handling)
```

### Infrastructure (shared across all deployment targets)

- **PostgreSQL 16** — port 5434 (local) / 5432 (default), user `postgres` / pass `mypassword`
- **Redis 7** — port 6379
- **Kafka 7.6 + Zookeeper** — port 9092
- **Monitoring**: Prometheus (9090), Grafana, Loki+Promtail or ELK stack

### Auth flow

```
Browser → POST /api/signin → api-gateway (pass-through) → auth-service
  → validates credentials → generates JWT → stores token in Redis (auth:token:<user>, 24h TTL)
  → publishes signin event to Kafka → returns JWT + user info

Browser → GET /api/grades → api-gateway
  → JwtAuthenticationFilter validates Bearer token → injects X-Authenticated-User header
  → forwards to grades-service → grades-service trusts the header (no JWT re-parse)
```

## Code Conventions & Patterns

### Java / Spring Boot

- **Lombok everywhere**: `@Slf4j`, `@RequiredArgsConstructor` (constructor injection), `@Builder` on DTOs, `@Getter/@Setter/@Builder` on entities
- **No `@Autowired` on fields** — always `private final` + constructor injection via `@RequiredArgsConstructor`
- **DTOs never expose entities** — controllers return `*Response` DTOs built via builder pattern
- **Entities**: `schema = "public"`, explicit `@Column(name = "...")`, `GenerationType.IDENTITY`, timestamps with `insertable = false, updatable = false`
- **No JPA cascade on relationships** — roles are fetched from DB via repository
- **Error handling**: Per-controller `@ExceptionHandler(IllegalArgumentException.class)` returning `Map.of("error", message)` — no global `@ControllerAdvice`
- **Validation**: `@Valid` on controller params, Jakarta Validation annotations on DTOs
- **Profile-specific configs**: `application.yml` (local), `application-docker.yml`, `application-k8s.yml` per service
- **`ddl-auto: validate`** in all profiles — DB schema must pre-exist

### TypeScript / Angular

- **Standalone components** — no NgModules anywhere
- **Zoneless** — `provideZonelessChangeDetection()` in app config
- **Signals** for reactive state — no `ChangeDetectorRef`
- **Functional guards/interceptors** — `CanActivateFn`, `HttpInterceptorFn`
- **Vitest** for testing — `vi.fn()` mocks, `ComponentFixture`, `provideHttpClient(withInterceptors())`
- **Prettier** for formatting — `npx prettier --check/write`
- **Template**: `ReactiveFormsModule` (not template-driven), `@for`/`@if` (new control flow)
- **All components lazy-loaded** via `loadComponent()` in routes
- **Schematics skip tests by default** (`"skipTests": true` in angular.json schematics)

## Non-obvious Gotchas

### Backend

- **Role MUST be fetched from DB** — never construct `new Role()` or `Role.builder().build()`. Role uses `GenerationType.IDENTITY` on its PK, so manually setting the PK causes constraint violations. Always use `roleRepository.findById(defaultRoleId)`. See `AuthService.signUp()`.
- **Auto sign-in after registration** — `signUp()` calls `signIn()` internally so the user gets a JWT immediately. This means `signUp()` tests must mock the full signIn chain (auth manager, token provider, Redis ops).
- **Dual auth strategy in auth-service**: `JwtAuthFilter` first checks `X-Authenticated-User` header (set by gateway), then falls back to Bearer JWT validation. Auth routes in the gateway bypass the JWT filter.
- **@CacheEvict on signUp but not signIn** — `signUp()` evicts Spring Cache entries (`users`, `users-email`). `signIn()` writes to Redis directly via `redisTemplate.opsForValue().set()` with 24h TTL — this is separate from the Spring Cache abstraction.
- **Redis serves two purposes**: (1) Spring `@Cacheable`/`@CacheEvict` abstraction, and (2) manual token storage via `RedisTemplate`.
- **Kafka manual offset management** — `AuthEventConsumer` calls `ack.acknowledge()` only after successful email delivery. Failed emails don't commit offsets → at-least-once delivery.
- **`firstName` fallback in Kafka event** — if `firstName` is null, `AuthEventProducer` substitutes the `username`.
- **Grades-service has `app.jwt.secret` in config but doesn't reference JWT in code** — it relies entirely on the gateway's `X-Authenticated-User` header.
- **`Grade` entity has no relationships** — standalone lookup table, no `@ManyToOne` etc.
- **Auth tests exclude Security auto-config** — `@WebMvcTest(controllers = AuthController.class, excludeAutoConfiguration = {SecurityAutoConfiguration.class, UserDetailsServiceAutoConfiguration.class})`
- **CORS exposes `Authorization` header** — needed for Angular to read JWT from response headers.
- **`package-lock.json` is gitignored** — `npm install` in CI creates a fresh lock file each time.
- **Test dependency**: Maven tests need Postgres (port 5432 by default) and Redis running in CI but use mockito for unit tests — integration tests may need real services running.
- **build-all.sh uses host Docker, not minikube's** — images built on host Docker, then `minikube image load` transfers them.

### Frontend

- **API base URL is hardcoded** to `http://localhost:8080` in `auth.service.ts` and `grade.service.ts` — update for non-local deploys.
- **Zoneless means no NgZone** — don't inject `NgZone` or use `zone.js` APIs. Signals handle change detection.
- **`jwt.interceptor.ts` is a functional interceptor** — not a class-based `HttpInterceptor`. Uses `inject()` at call time, not constructor time.
- **Test setup uses `provideHttpClient(withInterceptors())`** — `HttpClientTestingModule` is not used; tests use `provideHttpClient` + mocked services.

## Project Structure

```
backend/                          # Maven multi-module (parent POM)
├── pom.xml                       # Spring Boot 3.2.5, Spring Cloud 2023.0.1
├── eureka-server/                # Eureka service discovery
├── api-gateway/                  # Spring Cloud Gateway + JWT filter
├── auth-service/                 # JWT auth, Redis token store, Kafka producer
├── grades-service/               # Grade CRUD, Redis cache
└── notification-service/         # Kafka consumer → email

frontend/
├── angular.json                  # @angular/build:application builder
├── package.json                  # Angular 21, vitest 4, typescript 5.9
├── vitest.config.ts              # @analogjs/vite-plugin-angular
├── tsconfig.json                 # strict: true, ES2022
└── src/
    └── app/
        ├── app.ts / app.config.ts / app.routes.ts
        ├── guards/, interceptors/, models/, services/
        └── pages/ (auth, dashboard, grades)

docker-compose.yml                # Full stack: infra + services + monitoring
deploy-local/                     # Minikube deployment (build → load → kustomize)
k8s/                              # Vanilla Kubernetes (build → push → kustomize)
deploy-openshift/                 # OpenShift (build → push OC registry → kustomize)
docker/monitoring/                # Prometheus, Loki, Promtail, Grafana configs
.github/workflows/                # CI for backend (Maven, JDK 21) and frontend (npm, Node 22)
```

## CI Pipeline (GitHub Actions)

- **Backend**: JDK 21 (Temurin), Maven cache, `mvn -B clean compile -q` → `mvn -B test` → `mvn -B package -DskipTests`. Requires Postgres + Redis service containers.
- **Frontend**: Node 22, `npm ci` → `ng build --output-path=dist` → `npx prettier --check src/...`.