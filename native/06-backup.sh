#!/bin/bash
# =============================================================
# Этап 6. Резервное копирование pgBackRest
#   - архивирование WAL (archive-push)
#   - stanza-create, check
#   - полный бэкап
#   - контрольные записи для последующего PITR
# =============================================================
set -uo pipefail
PSQL="sudo -u postgres psql"

echo "=== 1. Конфигурация pgBackRest ==="
sudo mkdir -p /var/lib/pgbackrest
sudo chown postgres:postgres /var/lib/pgbackrest
sudo install -d -o postgres -g postgres -m 0750 /etc/pgbackrest
sudo tee /etc/pgbackrest/pgbackrest.conf >/dev/null <<'EOF'
[global]
repo1-path=/var/lib/pgbackrest
log-level-console=info
log-level-file=detail
compress-type=zst
process-max=2

[lab]
pg1-path=/var/lib/postgresql/18/main
pg1-port=5432
pg1-user=postgres
EOF

echo "=== 2. Включение архивирования WAL ==="
if ! grep -q "archive_mode" /etc/postgresql/18/main/conf.d/90-lab.conf; then
sudo tee -a /etc/postgresql/18/main/conf.d/90-lab.conf >/dev/null <<'EOF'

# ---- архивирование WAL ----
archive_mode = on
archive_command = 'pgbackrest --stanza=lab archive-push %p'
archive_timeout = 60
EOF
fi

sudo pg_ctlcluster 18 main restart
sleep 3
$PSQL -p 5432 -P pager=off -c "SHOW archive_mode;" -c "SHOW archive_command;"

echo "=== 3. stanza-create и check ==="
sudo -u postgres pgbackrest --stanza=lab stanza-create
sudo -u postgres pgbackrest --stanza=lab check

echo "=== 4. Полный бэкап ==="
sudo -u postgres pgbackrest --stanza=lab --type=full backup

echo "=== 5. Записи после бэкапа (для проверки PITR) ==="
sleep 3
$PSQL -p 5432 -d appdb -P pager=off \
  -c "INSERT INTO cluster_test(note) VALUES ('запись МЕЖДУ бэкапом и маркером') RETURNING id, created_at;"
sleep 2
$PSQL -p 5432 -d appdb -P pager=off \
  -c "INSERT INTO cluster_test(note) VALUES ('PITR-маркер: ПОСЛЕ целевой точки') RETURNING id, created_at;"

TARGET=$($PSQL -p 5432 -d appdb -tAc \
  "SELECT to_char((SELECT created_at FROM cluster_test WHERE note LIKE 'запись МЕЖДУ%') + interval '1 second', 'YYYY-MM-DD HH24:MI:SS')")
echo "ЦЕЛЕВАЯ ТОЧКА ДЛЯ PITR: $TARGET"

echo "=== 6. Закрытие сегмента WAL и ожидание архивации ==="
$PSQL -p 5432 -P pager=off -c "SELECT pg_switch_wal() AS switched;"
sleep 8
sudo -u postgres pgbackrest --stanza=lab info
echo "=== BACKUP DONE (target=$TARGET) ==="
