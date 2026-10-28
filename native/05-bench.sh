#!/bin/bash
# =============================================================
# Этап 5. Нагрузочное тестирование pgbench
#   - OLTP (TPC-B) на primary, порт 5432
#   - SELECT-only на standby, порт 5433
# =============================================================
set -uo pipefail

echo "=== 1. Инициализация тестовой БД (scale 20 = 2 000 000 счетов) ==="
sudo -u postgres pgbench -i -s 20 -p 5432 appdb 2>&1 | tail -5
sudo -u postgres psql -p 5432 -d appdb -P pager=off \
  -c "SELECT count(*) AS pgbench_accounts FROM pgbench_accounts;"
sleep 3

echo "=== 2. Таблицы pgbench видны на standby ==="
sudo -u postgres psql -p 5433 -d appdb -P pager=off \
  -c "SELECT count(*) AS pgbench_accounts_on_standby FROM pgbench_accounts;"

echo "=== 3. OLTP (TPC-B): primary, 10 клиентов, 2 потока, 30 с ==="
sudo -u postgres pgbench -c 10 -j 2 -T 30 -p 5432 appdb 2>&1 \
  | grep -E "transaction type|scaling factor|number of clients|number of threads|number of transactions actually|number of failed|latency average|initial connection time|tps ="

echo "=== 4. Повторный прогон OLTP (30 с) ==="
sudo -u postgres pgbench -c 10 -j 2 -T 30 -p 5432 appdb 2>&1 \
  | grep -E "number of transactions actually|number of failed|latency average|tps ="

echo "=== 5. SELECT-only на standby: 10 клиентов, 15 с ==="
sudo -u postgres pgbench -S -c 10 -T 15 -p 5433 appdb 2>&1 \
  | grep -E "transaction type|number of transactions actually|number of failed|latency average|tps ="

echo "=== 6. Standby остаётся read-only ==="
sudo -u postgres psql -p 5433 -d appdb -c "INSERT INTO cluster_test(note) VALUES ('запись на standby');" 2>&1 | head -3
echo "=== PGBENCH DONE ==="
