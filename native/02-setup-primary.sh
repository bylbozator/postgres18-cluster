#!/bin/bash
# =============================================================
# Этап 2. Настройка primary-узла (кластер 18/main, порт 5432)
#   - параметры в /etc/postgresql/18/main/conf.d/90-lab.conf
#   - pg_hba.conf: доступ на репликацию
#   - роль replicator, база appdb, тестовая таблица, слот репликации
# =============================================================
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

CONF=/etc/postgresql/18/main/conf.d/90-lab.conf
HBA=/etc/postgresql/18/main/pg_hba.conf

echo "=== 1. Параметры кластера (conf.d) ==="
sudo tee "$CONF" >/dev/null <<'EOF'
# ---- лабораторный кластер: primary ----
listen_addresses = '*'
port = 5432

# память (ВМ: 4 GB RAM)
shared_buffers = 512MB
effective_cache_size = 1536MB
work_mem = 16MB
maintenance_work_mem = 128MB

# WAL / репликация
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_keep_size = 128MB
hot_standby = on

# расширения Percona
shared_preload_libraries = 'pgaudit,pg_stat_monitor'

# логирование и аудит
log_min_duration_statement = 200ms
log_checkpoints = on
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %q%u@%d '
track_io_timing = on
pgaudit.log = 'write, ddl'
EOF

echo "=== 2. pg_hba: репликация и подключения с localhost ==="
sudo sed -i '/^# ---- lab replication ----/,$d' "$HBA"
sudo tee -a "$HBA" >/dev/null <<'EOF'
# ---- lab replication ----
host    replication     replicator      127.0.0.1/32            scram-sha-256
host    replication     replicator      ::1/128                 scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF

echo "=== 3. Перезапуск кластера main ==="
sudo pg_ctlcluster 18 main restart
sleep 3
sudo -u postgres psql -c "SELECT version();"

echo "=== 4. Роль репликации и база appdb ==="
sudo -u postgres psql <<'SQL'
SET password_encryption = 'scram-sha-256';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
  ELSE
    ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
  END IF;
END
$$;
SELECT 'role replicator ok' AS step;
SQL

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'appdb'" | grep -q 1 \
  || sudo -u postgres createdb -O postgres appdb

echo "=== 5. Тестовая таблица и слот репликации ==="
sudo -u postgres psql -d appdb <<'SQL'
CREATE TABLE IF NOT EXISTS cluster_test (
    id         serial PRIMARY KEY,
    note       text,
    created_at timestamptz DEFAULT now()
);
INSERT INTO cluster_test(note) VALUES ('запись-1 на primary'), ('запись-2 на primary');
SQL

sudo -u postgres psql -tc "SELECT 1 FROM pg_replication_slots WHERE slot_name = 'replica_slot'" | grep -q 1 \
  || sudo -u postgres psql -c "SELECT pg_create_physical_replication_slot('replica_slot');"

echo "=== 6. Итог ==="
sudo -u postgres psql -P pager=off -c "SHOW shared_preload_libraries;" \
  -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;" \
  -c "SELECT count(*) FROM cluster_test;" -d appdb
echo "=== PRIMARY CONFIGURED ==="
