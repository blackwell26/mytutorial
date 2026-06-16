#!/bin/bash
# scripts/setup-ec2.sh — Install all dependencies for MyTutorial on a fresh EC2 (Amazon Linux 2023 / Ubuntu 22.04)
set -euo pipefail

DISTRO=$(grep -oP '^ID="?\K\w+' /etc/os-release 2>/dev/null || echo "unknown")

echo "=== Installing MyTutorial prerequisites on ${DISTRO} ==="
echo ""

# ---- Java 21 (Temurin) ----
install_java() {
  if java -version 2>&1 | grep -q "21"; then
    echo "[OK] Java 21 already installed"
    return
  fi
  echo "--- Installing Java 21 (Eclipse Temurin) ---"
  case "$DISTRO" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq wget apt-transport-https
      wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
      echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/adoptium.list
      apt-get update -qq && apt-get install -y -qq temurin-21-jdk
      ;;
    amzn|rhel|centos)
      yum install -y wget
      rpm --import https://packages.adoptium.net/artifactory/api/gpg/key/public
      cat > /etc/yum.repos.d/adoptium.repo << 'YUMREPO'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/amazonlinux/$releasever/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
YUMREPO
      yum install -y temurin-21-jdk
      ;;
    *)
      echo "WARNING: Unknown distro. Install Java 21 manually."
      ;;
  esac
  java -version
}

# ---- Maven ----
install_maven() {
  if mvn -version &>/dev/null; then
    echo "[OK] Maven already installed"
    return
  fi
  echo "--- Installing Maven ---"
  MAVEN_VERSION=3.9.9
  wget -q "https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  tar xzf "apache-maven-${MAVEN_VERSION}-bin.tar.gz" -C /opt
  ln -sf "/opt/apache-maven-${MAVEN_VERSION}/bin/mvn" /usr/local/bin/mvn
  rm "apache-maven-${MAVEN_VERSION}-bin.tar.gz"
  mvn -version
}

# ---- PostgreSQL 16 ----
install_postgres() {
  if pg_isready &>/dev/null; then
    echo "[OK] PostgreSQL already running"
    return
  fi
  echo "--- Installing PostgreSQL 16 ---"
  case "$DISTRO" in
    ubuntu|debian)
      sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg
      echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
      apt-get update -qq && apt-get install -y -qq postgresql-16
      ;;
    amzn)
      amazon-linux-extras enable postgresql16 2>/dev/null || true
      yum install -y postgresql16-server postgresql16-devel
      /usr/pgsql-16/bin/postgresql-16-setup initdb
      ;;
    *)
      echo "WARNING: Unknown distro. Install PostgreSQL 16 manually."
      return
      ;;
  esac
  systemctl enable postgresql
  systemctl start postgresql
  # Create database and user
  su - postgres -c "psql -c \"ALTER USER postgres PASSWORD 'mypassword';\""
  # Configure listen_addresses
  PG_HBA=$(find /etc/postgresql -name pg_hba.conf 2>/dev/null | head -1 || echo "/var/lib/pgsql/16/data/pg_hba.conf")
  sed -i 's/local\s\+all\s\+postgres\s\+peer/local   all   postgres   md5/' "$PG_HBA"
  systemctl restart postgresql
  echo "[OK] PostgreSQL 16 installed. User: postgres, Password: mypassword"
}

# ---- Redis 7 ----
install_redis() {
  if redis-cli ping &>/dev/null; then
    echo "[OK] Redis already running"
    return
  fi
  echo "--- Installing Redis 7 ---"
  case "$DISTRO" in
    ubuntu|debian)
      curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" > /etc/apt/sources.list.d/redis.list
      apt-get update -qq && apt-get install -y -qq redis
      # Set password
      sed -i 's/# requirepass .*/requirepass mypassword/' /etc/redis/redis.conf
      sed -i 's/^requirepass .*/requirepass mypassword/' /etc/redis/redis.conf
      ;;
    amzn)
      amazon-linux-extras enable redis7 2>/dev/null || true
      yum install -y redis
      sed -i 's/# requirepass .*/requirepass mypassword/' /etc/redis/redis.conf
      sed -i 's/^requirepass .*/requirepass mypassword/' /etc/redis/redis.conf
      ;;
    *)
      echo "WARNING: Unknown distro. Install Redis 7 manually."
      return
      ;;
  esac
  systemctl enable redis
  systemctl start redis
  echo "[OK] Redis 7 installed. Password: mypassword"
}

# ---- Apache Kafka + Zookeeper ----
install_kafka() {
  if systemctl is-active --quiet kafka 2>/dev/null; then
    echo "[OK] Kafka already running"
    return
  fi
  echo "--- Installing Kafka 3.7 (ZooKeeper included) ---"
  KAFKA_VERSION="3.7.1"
  SCALA_VERSION="2.13"
  KAFKA_HOME="/opt/kafka"
  if [ ! -d "$KAFKA_HOME" ]; then
    wget -q "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    tar xzf "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" -C /opt
    mv "/opt/kafka_${SCALA_VERSION}-${KAFKA_VERSION}" "$KAFKA_HOME"
    rm "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
  fi

  # Create systemd service for ZooKeeper
  cat > /etc/systemd/system/zookeeper.service << 'ZOOKEEPER_SVC'
[Unit]
Description=Apache ZooKeeper
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/kafka/bin/zookeeper-server-start.sh /opt/kafka/config/zookeeper.properties
ExecStop=/opt/kafka/bin/zookeeper-server-stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
ZOOKEEPER_SVC

  # Create systemd service for Kafka
  cat > /etc/systemd/system/kafka.service << 'KAFKA_SVC'
[Unit]
Description=Apache Kafka
After=zookeeper.service

[Service]
Type=simple
User=root
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
KAFKA_SVC

  systemctl daemon-reload
  systemctl enable zookeeper kafka
  systemctl start zookeeper
  sleep 5
  systemctl start kafka
  echo "[OK] Kafka 3.7 installed at /opt/kafka"
}

# ---- Nginx ----
install_nginx() {
  if nginx -v 2>/dev/null; then
    echo "[OK] Nginx already installed"
    return
  fi
  echo "--- Installing Nginx ---"
  case "$DISTRO" in
    ubuntu|debian)
      apt-get install -y -qq nginx
      ;;
    amzn)
      yum install -y nginx
      ;;
  esac
  systemctl enable nginx
  echo "[OK] Nginx installed"
}

# ---- Run all ----
install_java
install_maven
echo ""
echo "=== Java + Maven installed ==="
echo ""
install_postgres
echo ""
install_redis
echo ""
install_kafka
echo ""
install_nginx
echo ""

echo "=== All prerequisites installed ==="
echo ""
echo "PostgreSQL:  localhost:5432  user=postgres  password=mypassword"
echo "Redis:       localhost:6379  password=mypassword"
echo "Kafka:       localhost:9092"
echo "Java:        21 (Temurin)"
echo "Maven:       3.9+"
echo "Nginx:       installed, configure with deploy-EC2/scripts/deploy.sh"
echo ""
echo "Next steps:"
echo "  1. Clone the repository and cd backend/"
echo "  2. Run: mvn clean package -DskipTests"
echo "  3. Run the deploy script"
