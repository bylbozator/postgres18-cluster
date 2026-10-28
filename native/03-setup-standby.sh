#!/bin/bash
# =============================================================
# Этап 3. Развёртывание standby-узла
#   - отдельный кластер 18/standby (порт 5433)
#   - pg_basebackup с primary (-R, физический слот)
#   - primary_conninfo + primary_slot_name (раздельно!)
# =============================================================
set -euxo pipefail

PGDATA_STANDBY=/var/lib/postgresql/18/standby
CONF=/etc/postgresql/18/standby/conf.d/90-lab.conf

echo "=== 1. Создание кластера standby (порт 5433) ==="
if ! pg_lsclusters -h | awk '{print $1"/"$2}' | grep -qx "18/standby"; then
    sudo pg_createcluster 18 standby --port 5433
fi
sudo pg_ctlcluster 18 standby stop 2>/dev/null || true

echo "=== 2. Очистка каталога данных и base backup с primary ==="
# ВАЖНО: каталог принадлежит postgres и закрыт (0700) — удаляем целиком,
# иначе glob /* не раскроется из-под обычного пользователя
sudo rm -rf "${PGDATA_STANDBY}"
sudo install -d -o postgres -g postgres -m 0700 "${PGDATA_STANDBY}"

sudo -u postgres env PGPASSWORD=replpass pg_basebackup \
    -h 127.0.0.1 -p 5432 -U replicator \
    -D "$PGDATA_STANDBY" -X stream -R -S replica_slot \
    --checkpoint=fast --progress --verbose

echo "=== 3. Параметры standby (conf.d) ==="
sudo mkdir -p /etc/postgresql/18/standby/conf.d
sudo tee "$CONF" >/dev/null <<'EOF'
# ---- лабораторный кластер: standby ----
listen_addresses = '*'
hot_standby = on
shared_buffers = 512MB
effective_cache_size = 1536MB
work_mem = 16MB
maintenance_work_mem = 128MB
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
shared_preload_libraries = 'pgaudit,pg_stat_monitor'
log_min_duration_statement = 200ms
log_line_prefix = '%m [%p] %q%u@%d '
EOF

echo "=== 4. Параметры подключения к primary (postgresql.auto.conf) ==="
sudo -u postgres tee "$PGDATA_STANDBY/postgresql.auto.conf" >/dev/null <<'EOF'
# primary_slot_name — отдельный параметр, НЕ внутри primary_conninfo
primary_conninfo = 'host=127.0.0.1 port=5432 user=replicator password=replpass application_name=replica'
primary_slot_name = 'replica_slot'
EOF

echo "=== 5. Запуск standby ==="
sudo pg_ctlcluster 18 standby start
sleep 5

echo "=== 6. Проверка репликации ==="
pg_lsclusters
sudo -u postgres psql -p 5432 -P pager=off \
  -c "SELECT pid, application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
sudo -u postgres psql -p 5433 -P pager=off \
  -c "SELECT pg_is_in_recovery() AS is_standby, pg_last_wal_receive_lsn() AS received, pg_last_wal_replay_lsn() AS replayed;"
sudo -u postgres psql -p 5433 -d appdb -P pager=off -c "SELECT * FROM cluster_test ORDER BY id;"
echo "=== STANDBY READY ==="
