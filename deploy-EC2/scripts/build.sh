#!/bin/bash
# scripts/build.sh — Build JARs and prepare deployment package for EC2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../backend" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/mytutorial-deploy}"
SERVICES=("eureka-server" "auth-service" "grades-service" "notification-service" "api-gateway")

echo "=== Building MyTutorial for EC2 deployment ==="
echo "Output: ${OUTPUT_DIR}"
echo ""

# 1. Build all JARs
echo "--- Building JARs with Maven ---"
cd "$PROJECT_DIR"
mvn clean package -DskipTests
echo ""

# 2. Prepare deployment directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"/{bin,config,lib}

# 3. Copy JARs
for svc in "${SERVICES[@]}"; do
  JAR=$(ls "$PROJECT_DIR/$svc/target/"*.jar 2>/dev/null | head -1)
  if [ -z "$JAR" ]; then
    echo "ERROR: No JAR found for ${svc}. Build failed."
    exit 1
  fi
  mkdir -p "$OUTPUT_DIR/lib/$svc"
  cp "$JAR" "$OUTPUT_DIR/lib/$svc/app.jar"
  echo "  [OK] ${svc}: $(basename "$JAR") → app.jar"
done

# 4. Copy EC2 Spring profiles
echo "--- Copying EC2 configuration ---"
mkdir -p "$OUTPUT_DIR/config"
cp -r "$SCRIPT_DIR/../env/"* "$OUTPUT_DIR/config/"
# Rename shared env to eureka-server since it's the per-service config for eureka
# Actually the shared application-ec2.yml at root of env/ is for eureka-server
echo "  [OK] EC2 profiles copied"

# 5. Copy systemd services
echo "--- Copying systemd service files ---"
cp "$SCRIPT_DIR/../systemd/"*.service "$OUTPUT_DIR/lib/"
echo "  [OK] systemd service files copied"

# 6. Copy Nginx config
echo "--- Copying Nginx config ---"
cp "$SCRIPT_DIR/../config/nginx/mytutorial.conf" "$OUTPUT_DIR/config/"
echo "  [OK] Nginx config copied"

# 7. Copy deploy script
echo "--- Copying deploy script ---"
cp "$SCRIPT_DIR/deploy.sh" "$OUTPUT_DIR/bin/"
chmod +x "$OUTPUT_DIR/bin/deploy.sh"
echo "  [OK] deploy.sh copied"

# 8. Create archive
cd /tmp
tar czf mytutorial-ec2.tar.gz -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"

echo ""
echo "=== Build complete ==="
echo "  Package: /tmp/mytutorial-ec2.tar.gz"
echo "  Size:    $(du -sh /tmp/mytutorial-ec2.tar.gz | cut -f1)"
echo ""
echo "To deploy:"
echo "  scp /tmp/mytutorial-ec2.tar.gz ec2-user@<EC2_IP>:/tmp/"
echo "  ssh ec2-user@<EC2_IP> sudo /tmp/mytutorial-ec2/bin/deploy.sh"
