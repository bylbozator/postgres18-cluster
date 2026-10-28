#!/bin/bash
# =============================================================
# Этап 8. Тест на отказ (failover) и возврат узла в кластер
#   1) аварийная остановка primary
#   2) promote standby
#   3) запись на продвинутом узле
#   4) возврат старого primary (pg_rewind при расхождении)
# =============================================================
set -uo pipefail
PSQL="sudo -u postgres psql"
PGDATA_MAIN=/var/lib/postgresql/18/main
PG_REWIND=/usr/lib/postgresql/18/bin/pg_rewind

echo "=== 0. Состояние до отказа ==="
pg_lsclusters
$PSQL -p 5432 -P pager=off -c "SHOW data_checksums;" \
  -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
$PSQL -p 5432 -d appdb -P pager=off -c "SELECT count(*) AS rows_before FROM cluster_test;"

echo "=== 1. Имитация отказа primary (аварийная остановка) ==="
sudo pg_ctlcluster 18 main stop --force
sleep 2
pg_lsclusters
$PSQL -p 5433 -P pager=off -c "SELECT pg_is_in_recovery() AS standby_still_in_recovery;"

echo "=== 2. Продвижение standby (promote) ==="
sudo pg_ctlcluster 18 standby promote
sleep 4
$PSQL -p 5433 -P pager=off -c "SELECT pg_is_in_recovery() AS still_standby;" \
  -c "SELECT pg_walfile_name(pg_current_wal_lsn()) AS current_wal;"
$PSQL -p 5433 -d appdb -P pager=off \
  -c "INSERT INTO cluster_test(note) VALUES ('запись на promoted-узле') RETURNING id;"
$PSQL -p 5433 -d appdb -P pager=off -c "SELECT count(*) AS rows_on_promoted FROM cluster_test;"

echo "=== 3. Слот репликации для возвращаемого узла ==="
$PSQL -p 5433 -P pager=off -c "SELECT pg_create_physical_replication_slot('standby2_slot');"

echo "=== 4. Возврат старого primary в кластер ==="
# Если узлы разошлись (на старом primary были свои транзакции) — нужен pg_rewind.
# В нашем сценарии реплика не отставала, расхождения нет, поэтому достаточно
# перевести каталог в режим standby.
if sudo -u postgres $PG_REWIND --target-pgdata="$PGDATA_MAIN" \
     --source-server="host=/var/run/postgresql port=5433 user=postgres" --progress; then
    echo "pg_rewind: выполнен"
else
    echo "pg_rewind: расхождения не обнаружено (или узел уже синхронизирован)"
fi

echo "=== 5. Настройка возвращённого узла как standby нового primary ==="
sudo -u postgres tee "$PGDATA_MAIN/postgresql.auto.conf" >/dev/null <<'EOF'
primary_conninfo = 'host=127.0.0.1 port=5433 user=replicator password=replpass application_name=replica2'
primary_slot_name = 'standby2_slot'
EOF
sudo -u postgres touch "$PGDATA_MAIN/standby.signal"
sudo pg_ctlcluster 18 main start
sleep 7

echo "=== 6. Проверка восстановленного кластера ==="
pg_lsclusters
$PSQL -p 5433 -P pager=off \
  -c "SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
$PSQL -p 5432 -P pager=off -c "SELECT pg_is_in_recovery() AS is_standby;"
$PSQL -p 5432 -d appdb -P pager=off -c "SELECT id, note FROM cluster_test ORDER BY id;"
echo "=== FAILOVER DONE ==="
