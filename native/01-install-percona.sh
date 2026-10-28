#!/bin/bash
# =============================================================
# Этап 1. Нативная установка Percona Distribution for PostgreSQL 18
# Стенд: Ubuntu 24.04 LTS (noble), без контейнеров
# =============================================================
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "=== 0. Базовые пакеты ==="
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg lsb-release

echo "=== 1. Подключение репозитория Percona ==="
cd /tmp
curl -fsSLO "https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb"
sudo dpkg -i "percona-release_latest.$(lsb_release -sc)_all.deb"
sudo apt-get update -y

echo "=== 2. Включение репозитория PPG 18 ==="
sudo percona-release setup ppg-18 -y || sudo percona-release setup ppg-18
sudo apt-get update -y

echo "=== 3. Установка сервера, клиента, расширений и pgBackRest ==="
sudo apt-get install -y \
  percona-postgresql-18 \
  percona-postgresql-client-18 \
  percona-postgresql-common \
  percona-postgresql-18-pgaudit \
  percona-pg-stat-monitor18 \
  percona-pgbackrest

echo "=== 4. Проверка ==="
psql --version
pg_lsclusters || true
pgbackrest version || true
dpkg -l | grep -E "percona-(postgresql|pgbackrest|pg-stat)" | awk '{print $2, $3}'

echo "=== DONE ==="
