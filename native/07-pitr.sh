#!/bin/bash
# =============================================================
# Этап 7. Восстановление на точку во времени (PITR)
#   Отдельный кластер 18/pitr (порт 5434) из бэкапа pgBackRest.
#   Рабочий кластер не затрагивается.
#
#   Использование: ./07-pitr.sh "2026-10-28 14:39:49"
# =============================================================
set -uo pipefail
PSQL="sudo -u postgres psql"
PGDATA_PITR=/var/lib/postgresql/18/pitr
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    echo "Укажите целевую точку: ./07-pitr.sh 'YYYY-MM-DD HH24:MI:SS'"
    exit 1
fi

echo "=== 1. Конфигурация кластера pitr (порт 5434) ==="
if ! pg_lsclusters -h | awk '{print $1"/"$2}' | grep -qx "18/pitr"; then
    sudo pg_createcluster 18 pitr --port 5434
fi
sudo pg_ctlcluster 18 pitr stop 2>/dev/null || true

echo "=== 2. Пустой каталог данных ==="
sudo rm -rf "$PGDATA_PITR"
sudo install -d -o postgres -g postgres -m 0700 "$PGDATA_PITR"

echo "=== 3. restore --type=time --target='$TARGET' ==="
# ВАЖНО: --pg1-path обязателен, иначе pgBackRest возьмёт путь primary
# из pgbackrest.conf и откажется работать с запущенным кластером
sudo -u postgres pgbackrest --stanza=lab --pg1-path="$PGDATA_PITR" \
    --type=time --target="$TARGET" --target-action=promote \
    --log-level-console=info restore

echo "=== 4. Параметры восстановления ==="
sudo grep -E "restore_command|recovery_target" "$PGDATA_PITR/postgresql.auto.conf"

echo "=== 5. Запуск: проигрывание WAL до целевой точки ==="
sudo pg_ctlcluster 18 pitr start
sleep 8
sudo grep -E "recovery stopping|selected new timeline|ready to accept" \
    /var/log/postgresql/postgresql-18-pitr.log | tail -4

echo "=== 6. Проверка результата ==="
$PSQL -p 5434 -P pager=off -c "SELECT pg_is_in_recovery() AS is_standby;"
$PSQL -p 5434 -d appdb -P pager=off \
  -c "SELECT id, note, created_at FROM cluster_test ORDER BY id;" \
  -c "SELECT count(*) AS pgbench_accounts FROM pgbench_accounts;" \
  -c "SELECT timeline_id FROM pg_control_checkpoint();"
echo "--- для сравнения: рабочий primary ---"
$PSQL -p 5432 -d appdb -P pager=off -c "SELECT count(*) AS rows_on_primary, max(id) AS max_id FROM cluster_test;"
echo "=== PITR DONE ==="
