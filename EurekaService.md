Good question. I didn't use it — I should have. The static list approach I gave you is a workaround that belongs in early prototypes, not a microservices architecture. Let me explain honestly, then implement Eureka properly.

## Why service discovery is the right choice

**The problem with static instance lists:**
- Every time you add/remove an instance you have to edit YAML and **restart the gateway**
- If an instance crashes, the gateway keeps sending traffic to it until you manually remove it
- It doesn't scale — 10 services × 3 instances each = a maintenance nightmare in config files
- Port numbers have to be manually coordinated across developers

**What Spring Service Discovery (Eureka) gives you:**
- Services **register themselves** on startup and **deregister on shutdown** automatically
- The gateway discovers instances dynamically — no restarts needed to scale
- Eureka has a heartbeat mechanism — dead instances are evicted within ~90 seconds
- You can run any number of instances on any port (including port 0 = random port)
- It's the standard Spring Cloud pattern for on-premises deployments

---

## Implementation

The plan: add a `eureka-server` module, then add Eureka client to `api-gateway`, `grades-service`, `auth-service`, and `notification-service`.

### Step 1 — Register eureka-server in parent POM

### Step 2 — Build the eureka-server module

### Step 3 — Add Eureka client dependency to all four services

### Step 4 — Add Eureka client config to each service's application.yml

### Step 5 — Clean up api-gateway: remove static list, keep lb:// routing

Now remove the `StaticInstanceConfig` class — it's no longer needed:

Validate all modules:

All five modules validate. Here's the full picture:

---

## Final architecture

```
                         ┌─────────────────────┐
                         │   eureka-server:8761 │  ← dashboard at http://localhost:8761
                         └──────────┬──────────┘
                    registers ▲     │ discovers
                               │     ▼
┌──────────────┐    lb://    ┌──────────────┐
│    Angular   │────────────►│  api-gateway │:8080
└──────────────┘             └──────┬───────┘
                                    │  lb://grades-service (round-robin)
                         ┌──────────┼──────────┐
                         ▼          ▼           ▼
                   grades:8082  grades:8092  grades:8093
                   (instance 1) (instance 2) (instance 3)
```

Every service registers itself with Eureka on startup. The gateway fetches the live registry every 30 seconds. When you start a new `grades-service` instance, it appears in Eureka within ~10 seconds and the gateway starts routing to it — **no config changes, no restarts**.

---

## Running multiple grades-service instances

```bash
# Start Eureka first — everything else depends on it
java -jar eureka-server/target/eureka-server-1.0.0-SNAPSHOT.jar

# Start as many grades-service instances as you want — any port
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8082
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8092
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=8093

# Or use port 0 to let the OS pick a free port automatically
java -jar grades-service/target/grades-service-1.0.0-SNAPSHOT.jar --server.port=0
```

Check the Eureka dashboard at **http://localhost:8761** — you'll see all registered instances listed under `GRADES-SERVICE` with their host/port.