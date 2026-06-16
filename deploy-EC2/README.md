# MyTutorial — EC2 Deployment (Traditional, No Docker)

Deploy MyTutorial's Spring Boot microservices to a single EC2 instance using pure JARs, systemd, and Nginx — no Docker, no Kubernetes.

## Architecture

```
                          ┌──────────────────────────────────────┐
                          │         Nginx (443/80)              │
                          │  SSL termination, rate limiting,     │
                          │  reverse proxy                      │
                          └──────────┬───────────────────────────┘
                                     │ http://localhost:8080
                          ┌──────────▼───────────────────────────┐
                          │         API Gateway (:8080)          │
                          │   Spring Cloud Gateway + JWT filter  │
                          └────┬──────┬──────┬───────────────────┘
                               │      │      │
                    ┌──────────▼┐ ┌──▼────┐ │ ┌───────────────────┐
                    │  Eureka   │ │ Auth  │ │ │     Grades        │
                    │  Server   │ │ (:8081)│ │ │     (:8082)      │
                    │  (:8761)  │ │       │ │ │                   │
                    └───────────┘ └──┬────┘ │ └────────┬──────────┘
                                     │      │          │
                    Redis (:6379) ◄──┘      │          │
                    Kafka  (:9092) ◄─────►──┼───► Notification  │
                    Postgres (:5432) ◄──────┘     (:8083)        │
                        Infrastructure              └────────────┘
```

## Prerequisites

| Component | Version | Port | Purpose |
|-----------|---------|------|---------|
| **Java** | 21 (Temurin) | — | Runtime |
| **Maven** | 3.9+ | — | Build |
| **PostgreSQL** | 16 | 5432 | Data storage |
| **Redis** | 7 | 6379 | Caching + token store |
| **Apache Kafka** | 3.7+ | 9092 | Event bus |
| **Nginx** | latest | 80/443 | Reverse proxy + SSL |

## Quick Start (Fresh EC2)

### 1. Set up infrastructure on the EC2 instance

```bash
# Copy and run the setup script (installs Java 21, Maven, Postgres, Redis, Kafka, Nginx)
ssh ec2-user@<EC2_IP>
sudo bash deploy-EC2/scripts/setup-ec2.sh
```

### 2. Build JARs on your build machine (or on the EC2)

```bash
# From the repo root on a machine with Maven + Java 21:
cd backend
mvn clean package -DskipTests

# Or use the build script which creates a deployment tarball:
./deploy-EC2/scripts/build.sh
# Produces: /tmp/mytutorial-ec2.tar.gz
```

### 3. Copy the package to EC2

```bash
scp /tmp/mytutorial-ec2.tar.gz ec2-user@<EC2_IP>:/tmp/
ssh ec2-user@<EC2_IP>
cd /tmp
tar xzf mytutorial-ec2.tar.gz
```

### 4. Install and start

```bash
sudo /tmp/mytutorial-ec2/bin/deploy.sh
```

### 5. Configure Nginx SSL and restart

```bash
# Install certs to /etc/nginx/ssl/
# Or use Let's Encrypt:
sudo dnf install -y certbot python3-certbot-nginx
sudo certbot --nginx -d api.mytutorial.example.com

sudo systemctl restart nginx
```

## Manual Deploy Steps

If you prefer to deploy step by step instead of using the scripts:

### Install dependencies

```bash
# See setup-ec2.sh for full automation. Manual equivalent:
sudo yum install -y java-21-amazon-corretto-devel maven
sudo amazon-linux-extras enable postgresql16 redis7
sudo yum install -y postgresql16-server redis nginx

# PostgreSQL
sudo /usr/pgsql-16/bin/postgresql-16-setup initdb
sudo systemctl enable --now postgresql
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'mypassword';"
sudo -u postgres createdb mytutorial

# Redis
sudo systemctl enable --now redis
sudo redis-cli CONFIG SET requirepass mypassword

# Kafka
# Download from https://kafka.apache.org/downloads to /opt/kafka
# See setup-ec2.sh for full systemd service definitions
```

### Build JARs

```bash
cd backend
mvn clean package -DskipTests
```

### Deploy

```bash
# Create directories
sudo mkdir -p /opt/mytutorial/{eureka-server,auth-service,grades-service,notification-service,api-gateway}
sudo mkdir -p /opt/mytutorial/config

# Copy JARs
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  sudo cp backend/$svc/target/*.jar /opt/mytutorial/$svc/app.jar
done

# Copy EC2 Spring profiles
sudo cp deploy-EC2/env/*.yml /opt/mytutorial/config/
# Or copy per-service configs:
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  if [ -d "deploy-EC2/env/$svc" ]; then
    sudo mkdir -p /opt/mytutorial/config/$svc
    sudo cp deploy-EC2/env/$svc/application-ec2.yml /opt/mytutorial/config/$svc/
  fi
done

# Copy systemd services
sudo cp deploy-EC2/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
```

### Start (in dependency order)

```bash
# 1. Eureka Server
sudo systemctl enable --now eureka-server

# Wait for Eureka health
sleep 15
curl http://localhost:8761/actuator/health

# 2. Auth, Grades, Notification (parallel)
sudo systemctl enable --now auth-service grades-service notification-service

# 3. API Gateway (last — depends on everything)
sudo systemctl enable --now api-gateway
```

## Service Startup Order

```
  1. eureka-server (:8761)     ─ no deps
  2. auth-service (:8081)      ─ needs Postgres, Redis, Kafka, Eureka
     grades-service (:8082)    ─ needs Postgres, Redis, Eureka
     notification-service(:8083)─ needs Kafka, Eureka
  3. api-gateway (:8080)       ─ needs Redis, Eureka, all upstream services
```

## Directory Layout on EC2

```
/opt/mytutorial/
├── eureka-server/app.jar
├── auth-service/app.jar
├── grades-service/app.jar
├── notification-service/app.jar
├── api-gateway/app.jar
└── config/
    ├── eureka-server/application-ec2.yml
    ├── auth-service/application-ec2.yml
    ├── grades-service/application-ec2.yml
    ├── notification-service/application-ec2.yml
    └── api-gateway/application-ec2.yml
```

## Management Commands

```bash
# Status
systemctl status eureka-server auth-service grades-service notification-service api-gateway

# Logs (follow)
journalctl -u auth-service -f

# Restart one service
sudo systemctl restart auth-service

# Restart all
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  sudo systemctl restart "$svc"
done

# Stop all
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  sudo systemctl stop "$svc"
done
```

## Health Checks

```bash
# Each service exposes Spring Actuator endpoints
curl http://localhost:8761/actuator/health    # Eureka
curl http://localhost:8081/actuator/health    # Auth
curl http://localhost:8082/actuator/health    # Grades
curl http://localhost:8083/actuator/health    # Notification
curl http://localhost:8080/actuator/health    # Gateway

# Prometheus metrics
curl http://localhost:8081/actuator/prometheus
```

## EC2 Profile (`application-ec2.yml`)

Each service has an EC2-specific Spring profile that overrides connection strings to use `localhost` instead of Docker service names or external IPs. Activated via `SPRING_PROFILES_ACTIVE=ec2` and `SPRING_CONFIG_ADDITIONAL_LOCATION` pointing to `/opt/mytutorial/config/<service>/`.

## Scaling Considerations

This is a **single-instance traditional deployment** suitable for:

| Scenario | Recommendation |
|----------|---------------|
| **Dev/Demo** | Single EC2 (t3.medium or larger) |
| **Staging** | Split Postgres/Redis/Kafka to separate instances |
| **Production** | Use Docker/K8s deployment instead |

To scale beyond one instance, migrate to the `k8s/` or `deploy-azure/` deployment sets.

## Troubleshooting

```bash
# Port already in use
sudo ss -tlnp | grep <port>

# Service won't start
sudo journalctl -u <service> -n 50 --no-pager

# PostgreSQL auth failure
sudo -u postgres psql -c "\du"
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'mypassword';"

# Kafka not connecting
sudo journalctl -u kafka -n 30 --no-pager
nc -zv localhost 9092

# View all logs in real time
for svc in eureka-server auth-service grades-service notification-service api-gateway; do
  journalctl -u "$svc" -f &
done
wait
```
