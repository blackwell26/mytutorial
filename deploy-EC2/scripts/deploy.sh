#!/bin/bash
# scripts/deploy.sh — Install JARs, configs, systemd services on EC2
set -euo pipefail

# This script runs ON the EC2 instance after the package is extracted.
# Prerequisites: setup-ec2.sh has been run already.

APP_DIR="/opt/mytutorial"
CONFIG_DIR="${APP_DIR}/config"
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")
STARTUP_ORDER=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

# Detect where this script is running from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"  # parent of bin/

echo "=== Deploying MyTutorial to EC2 ==="
echo ""

# 1. Create mytutorial user if not exists
if ! id -u mytutorial &>/dev/null; then
  echo "--- Creating mytutorial user ---"
  useradd --system --no-create-home --shell /sbin/nologin mytutorial
fi

# 2. Create application directories
echo "--- Creating application directories ---"
mkdir -p "$APP_DIR"
for svc in "${SERVICES[@]}"; do
  mkdir -p "${APP_DIR}/${svc}"
done
mkdir -p "$CONFIG_DIR"

# 3. Copy JARs
echo "--- Installing JARs ---"
for svc in "${SERVICES[@]}"; do
  if [ -f "${PACKAGE_DIR}/lib/${svc}/app.jar" ]; then
    cp "${PACKAGE_DIR}/lib/${svc}/app.jar" "${APP_DIR}/${svc}/app.jar"
    chown mytutorial:mytutorial "${APP_DIR}/${svc}/app.jar"
    chmod 644 "${APP_DIR}/${svc}/app.jar"
    echo "  [OK] ${svc}"
  else
    echo "  [WARN] No JAR for ${svc}, skipping"
  fi
done

# 4. Copy EC2 Spring profiles
echo "--- Installing configuration ---"
for svc in "${SERVICES[@]}"; do
  svc_config_dir="${CONFIG_DIR}/${svc}"
  mkdir -p "$svc_config_dir"
  # Copy service-specific profile if it exists
  if [ -f "${PACKAGE_DIR}/config/${svc}/application-ec2.yml" ]; then
    cp "${PACKAGE_DIR}/config/${svc}/application-ec2.yml" "${svc_config_dir}/application-ec2.yml"
  fi
  # Copy shared EC2 profile (generic defaults) — only for eureka-server
  # which is the only service without its own config directory in the package
  if [ "$svc" = "eureka-server" ] && [ -f "${PACKAGE_DIR}/config/application-ec2.yml" ]; then
    cp "${PACKAGE_DIR}/config/application-ec2.yml" "${svc_config_dir}/application-ec2.yml"
  fi
  chown -R mytutorial:mytutorial "$svc_config_dir"
done
echo "  [OK] Configuration installed"

# 5. Install systemd services
echo "--- Installing systemd services ---"
for svc in "${SERVICES[@]}"; do
  if [ -f "${PACKAGE_DIR}/lib/${svc}.service" ]; then
    cp "${PACKAGE_DIR}/lib/${svc}.service" "/etc/systemd/system/${svc}.service"
    chmod 644 "/etc/systemd/system/${svc}.service"
    echo "  [OK] ${svc}.service"
  fi
done
systemctl daemon-reload
echo ""

# 6. Install Nginx config (optional)
if [ -f "${PACKAGE_DIR}/config/mytutorial.conf" ]; then
  echo "--- Installing Nginx config ---"
  mkdir -p /etc/nginx/ssl
  cp "${PACKAGE_DIR}/config/mytutorial.conf" "/etc/nginx/conf.d/mytutorial.conf"
  echo "  [OK] Nginx config installed"
  echo "  NOTE: Replace /etc/nginx/ssl/mytutorial.crt/key with real certs"
  echo "  Then: systemctl restart nginx"
  echo ""
fi

# 7. Create DB (if PostgreSQL is running)
echo "--- Configuring PostgreSQL ---"
if pg_isready -q 2>/dev/null; then
  su - postgres -c "psql -c \"SELECT 1 FROM pg_database WHERE datname='mytutorial';\"" 2>/dev/null | grep -q 1 || \
    su - postgres -c "createdb mytutorial"
  echo "  [OK] Database 'mytutorial' ready"
else
  echo "  [WARN] PostgreSQL not running. Create database manually: CREATE DATABASE mytutorial;"
fi
echo ""

# 8. Start services in dependency order
echo "--- Starting services ---"
systemctl daemon-reload

for svc in "${STARTUP_ORDER[@]}"; do
  if [ ! -f "/etc/systemd/system/${svc}.service" ]; then
    echo "  [SKIP] ${svc} — no service file"
    continue
  fi
  echo "  Enabling ${svc}..."
  systemctl enable "${svc}" 2>/dev/null || true
  echo "  Starting ${svc}..."
  systemctl start "${svc}" || echo "  [WARN] ${svc} start failed (may be a dependency issue)"
  sleep 3
done

# 9. Verify
echo ""
echo "--- Service status ---"
for svc in "${SERVICES[@]}"; do
  STATUS=$(systemctl is-active "${svc}" 2>/dev/null || echo "not-found")
  printf "  %-25s %s\n" "${svc}:" "${STATUS}"
done

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Logs:  journalctl -u <service-name> -f"
echo "       e.g. journalctl -u auth-service -f"
echo ""
echo "Check health:"
echo "  curl http://localhost:8761/actuator/health    (Eureka)"
echo "  curl http://localhost:8081/actuator/health    (Auth)"
echo "  curl http://localhost:8080/actuator/health    (Gateway)"
echo ""
echo "Nginx: systemctl restart nginx (after configuring SSL)"
