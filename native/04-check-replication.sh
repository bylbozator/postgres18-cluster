#!/bin/bash
# =============================================================
# Этап 4. Проверка репликации, синхронного режима,
#         pgaudit и pg_stat_monitor
# =============================================================
set -uo pipefail
PSQL="sudo -u postgres psql"

echo "=== 1. Распространение данных primary -> standby ==="
$PSQL -p 5432 -d appdb -P pager=off \
  -c "INSERT INTO cluster_test(note) VALUES ('проверка репликации') RETURNING id, note, created_at;"
sleep 2
$PSQL -p 5433 -d appdb -P pager=off -c "SELECT id, note FROM cluster_test ORDER BY id;"

echo "=== 2. Синхронная репликация ==="
$PSQL -p 5432 -P pager=off -c "ALTER SYSTEM SET synchronous_standby_names = 'replica';" \
  -c "SELECT pg_reload_conf();"
sleep 2
$PSQL -p 5432 -P pager=off -c "SHOW synchronous_standby_names;"
$PSQL -p 5432 -d appdb -P pager=off -c "INSERT INTO cluster_test(note) VALUES ('синхронная запись') RETURNING id;"
$PSQL -p 5432 -P pager=off -c "SELECT application_name, state, sync_state, sync_priority FROM pg_stat_replication;"

echo "--- возврат в асинхронный режим ---"
$PSQL -p 5432 -P pager=off -c "ALTER SYSTEM SET synchronous_standby_names = '';" \
  -c "SELECT pg_reload_conf();"
sleep 1
$PSQL -p 5432 -P pager=off -c "SHOW synchronous_standby_names;" \
  -c "SELECT application_name, sync_state FROM pg_stat_replication;"

echo "=== 3. pg_stat_monitor ==="
$PSQL -p 5432 -d appdb -P pager=off -c "CREATE EXTENSION IF NOT EXISTS pg_stat_monitor;"
$PSQL -p 5432 -d appdb -P pager=off -c "SELECT count(*) FROM cluster_test;" 2>/dev/null
$PSQL -p 5432 -d appdb -P pager=off -c "SELECT userid::regrole AS usr, datname, calls, round(total_exec_time::numeric, 2) AS total_ms, left(query, 60) AS query FROM pg_stat_monitor ORDER BY total_exec_time DESC LIMIT 5;"

echo "=== 4. pgaudit ==="
$PSQL -p 5432 -P pager=off -c "SHOW pgaudit.log;"
$PSQL -p 5432 -d appdb -P pager=off -c "CREATE TABLE IF NOT EXISTS audit_check(id int); INSERT INTO audit_check VALUES (1);"
sleep 1
sudo grep -h "AUDIT" /var/log/postgresql/postgresql-18-main.log | tail -5

echo "=== 5. Версии и пути ==="
$PSQL -p 5432 -P pager=off -c "SELECT version();" -c "SHOW data_directory;" -c "SHOW config_file;"
echo "=== CHECKS DONE ==="
