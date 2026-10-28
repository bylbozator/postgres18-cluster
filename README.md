# Отчёт по теме

## «Установка, настройка и тестирование PostgreSQL 18 кластера на базе Percona Distribution for PostgreSQL»

**Выполнила:** Михайлова Анастасия Николаевна

> **Статус работы: выполнена.** Развёртывание **нативное**: пакеты из репозитория Percona
> установлены в виртуальную машину с Ubuntu 24.04 (systemd, `pg_createcluster`/`pg_ctlcluster`),
> контейнеры не используются.
>
> **Обновлено:** 28.10.2026

---

## 1. Цель и задачи работы

**Цель:** развернуть, настроить и протестировать двухузловой кластер СУБД PostgreSQL 18
на базе Percona Distribution for PostgreSQL с потоковой репликацией, резервным копированием,
восстановлением на точку во времени и проверкой на отказ.

**Задачи:**

1. Установить Percona Distribution for PostgreSQL 18 нативно (пакеты, без контейнеров).
2. Инициализировать кластеры, разобраться с раскладкой Debian/Ubuntu (`/etc/postgresql`, `/var/lib/postgresql`).
3. Настроить primary-узел: параметры, аутентификация, роль репликации, слот.
4. Настроить потоковую репликацию (streaming replication, hot standby).
5. Провести нагрузочное тестирование pgbench на primary и на реплике.
6. Проверить компоненты дистрибутива Percona: pgaudit, pg_stat_monitor.
7. Настроить резервное копирование и архивирование WAL (pgBackRest).
8. Отработать восстановление на точку во времени (PITR).
9. Проверить сценарий отказа: promote реплики и возврат узла в кластер.
10. Оформить результаты в отчёт.

### 1.1. Статус выполнения этапов

| № | Этап | Статус |
|---|---|---|
| 1 | Установка Percona Distribution for PostgreSQL 18 (apt) | ✅ выполнен |
| 2 | Инициализация кластеров (main, standby, pitr) | ✅ выполнен |
| 3 | Настройка primary-узла (параметры, pg_hba, роль, слот) | ✅ выполнен |
| 4 | Потоковая репликация (streaming + hot standby) | ✅ выполнен |
| 5 | Нагрузочное тестирование pgbench | ✅ выполнен |
| 6 | Компоненты Percona: pgaudit, pg_stat_monitor | ✅ выполнен |
| 7 | Резервное копирование pgBackRest | ✅ выполнен |
| 8 | Восстановление на точку во времени (PITR) | ✅ выполнен |
| 9 | Тест на отказ (failover) и возврат узла | ✅ выполнен |

---

## 2. Стенд и архитектура

### 2.1. Виртуальная машина

Работа выполнялась в виртуальной машине Hyper-V (второй гипервизор не нужен — Hyper-V уже
включён в системе). Система ставилась из облачного образа Ubuntu 24.04: cloud-init при первом
запуске создаёт пользователя, кладёт SSH-ключ и ставит KVP-агент для передачи IP в Hyper-V.
Скрипт создания ВМ — `native/vm/create-vm.ps1`, cloud-init — `native/vm/user-data`.

| Параметр | Значение |
|---|---|
| Гипервизор | Hyper-V (поколение 2, Secure Boot выключен — образ подписан, но для лаборатории не нужен) |
| Гостевая ОС | Ubuntu 24.04.5 LTS (noble) |
| Ядро | 6.8.0-147-generic |
| vCPU | 4 |
| RAM | 4 GB |
| Диск | 40 GB (динамический VHDX, занято ~4 GB) |
| Сеть | Hyper-V Default Switch (NAT), адрес `172.19.168.241` |
| SSH | пользователь `student`, вход по ключу Ed25519 |

### 2.2. Узлы кластера

Оба «сервера» кластера — это два независимых кластера PostgreSQL на одной ВМ
(классическая схема для лабораторной: разные порты, разные каталоги данных и конфигурации).
Третий кластер — восстановленная копия для проверки PITR.

| Кластер | Роль | Порт | Каталог данных | Конфигурация | Состояние |
|---|---|---|---|---|---|
| `18/main` | primary | 5432 | `/var/lib/postgresql/18/main` | `/etc/postgresql/18/main` | online |
| `18/standby` | hot standby (реплика) | 5433 | `/var/lib/postgresql/18/standby` | `/etc/postgresql/18/standby` | online |
| `18/pitr` | восстановленная копия (PITR) | 5434 | `/var/lib/postgresql/18/pitr` | `/etc/postgresql/18/pitr` | online |

### 2.3. Почему нативная установка

| Аспект | Нативно (этот отчёт) |
|---|---|
| Установка | `apt` из репозитория Percona (`percona-release setup ppg-18`) |
| Управление | `pg_createcluster`, `pg_ctlcluster`, `pg_lsclusters` (пакет `percona-postgresql-common`) |
| Каталоги | конфигурация `/etc/postgresql/18/<cluster>`, данные `/var/lib/postgresql/18/<cluster>` |
| Логи | `/var/log/postgresql/postgresql-18-<cluster>.log` |
| Расширения | `.so` из `/usr/lib/postgresql/18/lib` (pgaudit, pg_stat_monitor) |
| Автозапуск | systemd (`postgresql@18-main.service`) |

---

## 3. Этап 1. Установка Percona Distribution for PostgreSQL 18

### 3.1. Подключение репозитория Percona

```bash
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg lsb-release

cd /tmp
curl -fsSLO "https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb"
sudo dpkg -i "percona-release_latest.$(lsb_release -sc)_all.deb"
sudo apt-get update -y

sudo percona-release setup ppg-18
sudo apt-get update -y
```

`percona-release setup ppg-18` включает репозиторий Percona Distribution for PostgreSQL 18
(для Ubuntu 24.04 — ветка `noble`).

### 3.2. Установка пакетов

```bash
sudo apt-get install -y \
  percona-postgresql-18 \
  percona-postgresql-client-18 \
  percona-postgresql-common \
  percona-postgresql-18-pgaudit \
  percona-pg-stat-monitor18 \
  percona-pgbackrest
```

Во время установки `percona-postgresql-common` автоматически создаёт первый кластер
`18/main` (`initdb` в `/var/lib/postgresql/18/main`) и регистрирует его в systemd.

### 3.3. Версии установленных компонентов

```
$ psql --version
psql (PostgreSQL) 18.6 - Percona Server for PostgreSQL 18.6.1

$ pgbackrest version
pgBackRest 2.59.1
```

| Пакет | Версия |
|---|---|
| `percona-postgresql-18` | `3:18.6-1.noble` |
| `percona-postgresql-client-18` | `3:18.6-1.noble` |
| `percona-postgresql-common` | `1:293-1.noble` |
| `percona-postgresql-18-pgaudit` | `1:18.0-4.noble` |
| `percona-pg-stat-monitor18` | `1:2.4.0-1.noble` |
| `percona-pgbackrest` | `1:2.59.1-1.noble` |
| `percona-postgresql-18-jit` | `3:18.6-1.noble` (зависимость) |

### 3.4. Проверка установки

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory              Log file
18  main    5432 online postgres /var/lib/postgresql/18/main /var/log/postgresql/postgresql-18-main.log
```

```
$ psql -c "SELECT version();"
 PostgreSQL 18.6 - Percona Server for PostgreSQL 18.6.1 on x86_64-pc-linux-gnu,
 compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, 64-bit
```

---

## 4. Этап 2. Инициализация кластеров

### 4.1. Раскладка Debian/Ubuntu

В отличие от «ручного» `initdb`, пакеты Percona (как и штатный PostgreSQL в Debian/Ubuntu)
разделяют **конфигурацию и данные**:

```
/etc/postgresql/18/main/          <- конфигурация (postgresql.conf, pg_hba.conf, conf.d/)
/var/lib/postgresql/18/main/      <- каталог данных (PG_VERSION, base/, global/, WAL)
/var/log/postgresql/              <- логи кластеров
```

Это удобно для лабораторной: несколько кластеров одной версии живут рядом и не мешают друг другу.

### 4.2. Создание кластеров standby и pitr

```bash
sudo pg_createcluster 18 standby --port 5433
sudo pg_createcluster 18 pitr --port 5434
```

`pg_createcluster` выполняет `initdb`, создаёт конфигурацию в `/etc/postgresql/18/<cluster>`
и запись для `pg_ctlcluster`. Для standby данные, полученные `initdb`, затем заменяются
копией с primary (см. этап 4).

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory                 Log file
18  main    5432 online postgres /var/lib/postgresql/18/main    /var/log/postgresql/postgresql-18-main.log
18  pitr    5434 online postgres /var/lib/postgresql/18/pitr    /var/log/postgresql/postgresql-18-pitr.log
18  standby 5433 online postgres /var/lib/postgresql/18/standby /var/log/postgresql/postgresql-18-standby.log
```

---

## 5. Этап 3. Настройка primary-узла

### 5.1. Параметры кластера

Параметры вынесены в отдельный файл `/etc/postgresql/18/main/conf.d/90-lab.conf`
(каталог `conf.d` подключается из `postgresql.conf` штатно, основной файл не правится):

```ini
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

# архивирование WAL (добавлено на этапе 7)
archive_mode = on
archive_command = 'pgbackrest --stanza=lab archive-push %p'
archive_timeout = 60
```

Обоснование ключевых значений (ВМ 4 GB RAM):

| Параметр | Значение | Зачем |
|---|---|---|
| `shared_buffers` | 512 MB (12.5 % RAM) | кэш страниц; больше при 4 GB не даёт выигрыша |
| `effective_cache_size` | 1536 MB | подсказка планировщику про кэш ОС |
| `work_mem` | 16 MB | сортировки/хеши без свопа при 10 клиентах |
| `wal_level` | `replica` | достаточно для потоковой репликации |
| `max_wal_senders` / `max_replication_slots` | 10 | с запасом под реплику и ручные слоты |
| `wal_keep_size` | 128 MB | страховка, если реплика отстанет (слот — основная защита) |
| `hot_standby` | `on` | реплика принимает read-only запросы |
| `shared_preload_libraries` | `pgaudit,pg_stat_monitor` | библиотеки требуют загрузки при старте |
| `archive_mode` / `archive_command` | `on` / `pgbackrest ... archive-push` | непрерывное архивирование WAL |

### 5.2. Аутентификация (`pg_hba.conf`)

В конец `/etc/postgresql/18/main/pg_hba.conf` добавлены правила:

```
# ---- lab replication ----
host    replication     replicator      127.0.0.1/32            scram-sha-256
host    replication     replicator      ::1/128                 scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
```

Локальные подключения администратора (`local all postgres peer`) остались штатными:
`sudo -u postgres psql` работает без пароля, а сетевое подключение требует пароль.
`scram-sha-256` — современный метод аутентификации, пароли в открытом виде не летают.

### 5.3. Роль репликации и база данных

```sql
SET password_encryption = 'scram-sha-256';
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';

CREATE DATABASE appdb;
```

### 5.4. Тестовая таблица и слот репликации

```sql
CREATE TABLE cluster_test (
    id         serial PRIMARY KEY,
    note       text,
    created_at timestamptz DEFAULT now()
);
INSERT INTO cluster_test(note) VALUES ('запись-1 на primary'), ('запись-2 на primary');

SELECT pg_create_physical_replication_slot('replica_slot');
```

```
=# SELECT slot_name, slot_type, active FROM pg_replication_slots;
  slot_name   | slot_type | active
--------------+-----------+--------
 replica_slot | physical  | f
```

Физический слот удерживает WAL до подтверждения репликой — primary не «затрёт» сегменты,
которые ещё нужны standby.

### 5.5. Замечание про `shared_preload_libraries`

Список библиотек задан **в конфигурационном файле**, а не через `ALTER SYSTEM`.
Это принципиально: `ALTER SYSTEM SET shared_preload_libraries = 'pgaudit,pg_stat_monitor'`
может записать значение с лишними кавычками (`'"pgaudit,pg_stat_monitor"'`), после чего
сервер падает с `FATAL: could not access file`. Подробнее — приложение Г.

---

## 6. Этап 4. Потоковая репликация

### 6.1. Копирование данных с primary (`pg_basebackup`)

```bash
sudo pg_ctlcluster 18 standby stop
sudo rm -rf /var/lib/postgresql/18/standby
sudo install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18/standby

sudo -u postgres env PGPASSWORD=replpass pg_basebackup \
    -h 127.0.0.1 -p 5432 -U replicator \
    -D /var/lib/postgresql/18/standby -X stream -R -S replica_slot \
    --checkpoint=fast --progress --verbose
```

```
pg_basebackup: write-ahead log end point: 0/2000158
pg_basebackup: waiting for background process to finish streaming ...
pg_basebackup: syncing data to disk ...
pg_basebackup: renaming backup_manifest.tmp to backup_manifest
pg_basebackup: base backup completed
```

Ключи: `-X stream` — WAL передаётся вместе с копией, `-R` — записать параметры репликации,
`-S replica_slot` — использовать созданный слот.

### 6.2. Параметры подключения standby

`-R` создаёт файл `standby.signal` и пишет `primary_conninfo`. Слот указывается
**отдельным параметром**:

```ini
# /var/lib/postgresql/18/standby/postgresql.auto.conf
primary_conninfo = 'host=127.0.0.1 port=5432 user=replicator password=replpass application_name=replica'
primary_slot_name = 'replica_slot'
```

Если попытаться вписать `primary_slot_name` внутрь строки `primary_conninfo`, сервер
не стартует: `FATAL: invalid connection string syntax: invalid connection option "primary_slot_name"`
(см. приложение Г).

### 6.3. Запуск и проверка

```bash
sudo pg_ctlcluster 18 standby start
```

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory                 Log file
18  main    5432 online postgres /var/lib/postgresql/18/main    /var/log/postgresql/postgresql-18-main.log
18  standby 5433 online postgres /var/lib/postgresql/18/standby /var/log/postgresql/postgresql-18-standby.log

=# SELECT pid, application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;
  pid  | application_name |   state   | sync_state | sent_lsn  | replay_lsn
-------+------------------+-----------+------------+-----------+------------
 15377 | replica          | streaming | async      | 0/3000000 | 0/3000000

=# SELECT pg_is_in_recovery() AS is_standby,
          pg_last_wal_receive_lsn() AS received,
          pg_last_wal_replay_lsn()  AS replayed;      -- на порту 5433
 is_standby | received  | replayed
------------+-----------+-----------
 t          | 0/3000000 | 0/3000000
```

Реплика в режиме hot standby: принимает read-only запросы, `sent_lsn = replay_lsn` — отставания нет.

### 6.4. Проверка распространения данных

```
=# INSERT INTO cluster_test(note) VALUES ('проверка репликации') RETURNING id, note;   -- 5432
 id |        note
----+---------------------
  3 | проверка репликации

=# SELECT id, note FROM cluster_test ORDER BY id;                                       -- 5433
 id |        note
----+---------------------
  1 | запись-1 на primary
  2 | запись-2 на primary
  3 | проверка репликации
```

### 6.5. Синхронная репликация

```sql
ALTER SYSTEM SET synchronous_standby_names = 'replica';
SELECT pg_reload_conf();
```

```
=# SELECT application_name, state, sync_state, sync_priority FROM pg_stat_replication;
 application_name |   state   | sync_state | sync_priority
------------------+-----------+------------+---------------
 replica          | streaming | sync       |             1
```

После проверки режим возвращён в асинхронный (`synchronous_standby_names = ''`,
`sync_state = async`): при синхронном режиме без доступной реплики запись на primary
блокируется, для лаборатории это неудобно по умолчанию.

---

## 7. Этап 5. Нагрузочное тестирование (pgbench)

### 7.1. Инициализация тестовой базы

```bash
sudo -u postgres pgbench -i -s 20 -p 5432 appdb
```

```
done in 3.28 s (drop tables 0.00 s, create tables 0.01 s, client-side generate 2.31 s,
vacuum 0.28 s, primary keys 0.67 s).

=# SELECT count(*) AS pgbench_accounts FROM pgbench_accounts;
 2000000
```

2 000 000 строк в `pgbench_accounts`; таблицы pgbench сразу видны на standby
(`SELECT count(*)` на 5433 → `2000000`).

### 7.2. Результаты

| Тест | Узел | Параметры | tps | Средняя задержка | Транзакций | Ошибок |
|---|---|---|---|---|---|---|
| TPC-B (чтение+запись) | primary | `-c 10 -j 2 -T 30` | **1329.77** | 7.520 ms | 39 885 | 0 (0.000%) |
| TPC-B (повторный прогон) | primary | `-c 10 -j 2 -T 30` | **1512.07** | 6.613 ms | 45 352 | 0 (0.000%) |
| SELECT-only | standby | `-S -c 10 -T 15` | **39 716.32** | 0.252 ms | 594 452 | 0 (0.000%) |

Полный вывод OLTP-прогона:

```
transaction type: <builtin: TPC-B (sort of)>
scaling factor: 20
number of clients: 10
number of threads: 2
number of transactions actually processed: 39885
number of failed transactions: 0 (0.000%)
latency average = 7.520 ms
initial connection time = 22.733 ms
tps = 1329.766441 (without initial connection time)
```

Вывод SELECT-only на реплике:

```
transaction type: <builtin: select only>
number of transactions actually processed: 594452
number of failed transactions: 0 (0.000%)
latency average = 0.252 ms
tps = 39716.323050 (without initial connection time)
```

### 7.3. Проверка, что реплика остаётся read-only

```
=# INSERT INTO cluster_test(note) VALUES ('запись на standby');     -- порт 5433
ERROR:  cannot execute INSERT in a read-only transaction
```

### 7.4. Выводы по тестам

- OLTP-нагрузка упирается в запись WAL и синхронизацию (`fsync`), поэтому 1.3–1.5 тыс. tps —
  нормальный результат для 4 vCPU и диска ВМ.
- Реплика даёт **~26–30×** больше tps на read-only нагрузке, чем primary на OLTP:
  чтение снимает с primary значительную часть работы.
- Разброс между двумя OLTP-прогонами (1329 vs 1512) объясняется состоянием кэшей и
  контрольными точками; ошибок нет ни в одном прогоне.
- На результат влияет включённый аудит: за время тестов pgaudit записал **340 974** строки
  в лог (каждая пишущая транзакция pgbench — это `INSERT`/`UPDATE`). В «боевом» режиме
  аудит обычно сужают до конкретных таблиц/ролей.

---

## 8. Этап 6. Компоненты Percona

### 8.1. pgaudit — аудит запросов

Библиотека загружается через `shared_preload_libraries`, политика — `pgaudit.log = 'write, ddl'`.

```
=# SHOW pgaudit.log;
 write, ddl
```

Пример записей в `/var/log/postgresql/postgresql-18-main.log`:

```
2026-10-28 14:39:48.192 UTC [15989] postgres@appdb LOG:  AUDIT: SESSION,1,1,WRITE,INSERT,,,
  "INSERT INTO cluster_test(note) VALUES ('запись МЕЖДУ бэкапом и маркером') RETURNING id, created_at",<not logged>
2026-10-28 14:39:50.243 UTC [15993] postgres@appdb LOG:  AUDIT: SESSION,1,1,WRITE,INSERT,,,
  "INSERT INTO cluster_test(note) VALUES ('PITR-маркер: ПОСЛЕ целевой точки') RETURNING id, created_at",<not logged>
```

Аудит фиксирует класс операции (`WRITE`/`DDL`), объект, роль и текст запроса.

### 8.2. pg_stat_monitor — мониторинг запросов

```sql
CREATE EXTENSION pg_stat_monitor;
```

```
=# SELECT userid::regrole AS usr, datname, calls,
          round(total_exec_time::numeric, 2) AS total_ms,
          left(query, 60) AS query
   FROM pg_stat_monitor ORDER BY total_exec_time DESC LIMIT 5;

   usr    | datname  | calls | total_ms |                           query
----------+----------+-------+----------+-----------------------------------------------------------
 postgres | postgres |     1 |   132.86 | CREATE DATABASE appdb OWNER postgres
 postgres | appdb    |     1 |    20.83 | CREATE EXTENSION IF NOT EXISTS pg_stat_monitor
 postgres | postgres |     2 |    16.86 | ALTER SYSTEM SET synchronous_standby_names = 'replica'
 postgres | postgres |     1 |    10.71 | SELECT pg_create_physical_replication_slot('replica_slot')
 postgres | postgres |     1 |     8.50 | DO $$ ... $$;
```

В отличие от `pg_stat_statements`, pg_stat_monitor хранит запросы по «корзинам» времени
с гистограммами — удобно смотреть, что происходило в конкретный интервал.

### 8.3. Остальные компоненты дистрибутива

В репозитории PPG 18 доступны (в этой работе не настраивались, но могут быть включены
как развитие):

| Компонент | Назначение |
|---|---|
| `percona-patroni` + `etcd` | автоматический failover |
| `percona-pgbouncer`, `percona-haproxy`, `percona-pgpool2` | пулирование соединений, балансировка |
| `percona-pg-tde18` | шифрование данных на диске (TDE) |
| `percona-postgresql-18-wal2json` | логическая репликация/CDC |
| `percona-postgresql-18-pgvector`, `percona-postgis` | векторный поиск, геоданные |
| `percona-pgbadger` | анализ логов PostgreSQL |
| `percona-pgbackrest` | резервное копирование (используется в работе) |

---

## 9. Этап 7. Резервное копирование (pgBackRest)

### 9.1. Конфигурация

```ini
# /etc/pgbackrest/pgbackrest.conf
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
```

### 9.2. Архивирование WAL

```
=# SHOW archive_mode;
 on

=# SHOW archive_command;
 pgbackrest --stanza=lab archive-push %p
```

### 9.3. Создание stanza и проверка архива

```
$ sudo -u postgres pgbackrest --stanza=lab stanza-create
INFO: stanza-create for stanza 'lab' on repo1
INFO: stanza-create command end: completed successfully (41ms)

$ sudo -u postgres pgbackrest --stanza=lab check
INFO: check repo1 configuration (primary)
INFO: check repo1 archive for WAL (primary)
INFO: WAL segment 000000010000000000000014 successfully archived to
      '/var/lib/pgbackrest/archive/lab/18-1/0000000100000000000000/000000010000000000000014-...zst' on repo1
INFO: check command end: completed successfully (320ms)
```

### 9.4. Полный бэкап

```
$ sudo -u postgres pgbackrest --stanza=lab --type=full backup
INFO: execute backup start: backup begins after the next regular checkpoint completes
INFO: backup start archive = 000000010000000000000015, lsn = 0/15000028
INFO: backup stop archive = 000000010000000000000016, lsn = 0/16000050
INFO: new backup label = 20261028-143938F
INFO: full backup size = 335.9MB, file total = 1286
INFO: backup command end: completed successfully (6354ms)
```

### 9.5. Состояние репозитория

```
$ sudo -u postgres pgbackrest --stanza=lab info
stanza: lab
    status: ok
    cipher: none

    db (current)
        wal archive min/max (18): 00000001000000000000000C/000000010000000000000018

        full backup: 20261028-143938F
            timestamp start/stop: 2026-10-28 14:39:38+00 / 2026-10-28 14:39:44+00
            wal start/stop: 000000010000000000000015 / 000000010000000000000016
            database size: 335.9MB, database backup size: 335.9MB
            repo1: backup set size: 21.2MB, backup size: 21.2MB
```

Сжатие `zst`: **335.9 MB → 21.2 MB** (~15.8×), весь репозиторий со WAL занимает 37 MB.
Бэкап делается на ходу, без остановки кластера; согласованность обеспечивает `pg_start_backup`-механика
внутри pgBackRest + архивирование WAL.

---

## 10. Этап 8. Восстановление на точку во времени (PITR)

### 10.1. Сценарий проверки

1. Сделан полный бэкап `20261028-143938F` (этап 7).
2. После бэкапа добавлены две записи:
   - id=5, `запись МЕЖДУ бэкапом и маркером` — `14:39:48.19`;
   - id=6, `PITR-маркер: ПОСЛЕ целевой точки` — `14:39:50.24`.
3. Целевая точка восстановления: **`2026-10-28 14:39:49`** — между ними.
   Ожидаемый результат: запись id=5 есть, маркер id=6 отсутствует.
4. Сегмент WAL закрыт и заархивирован:

   ```
   =# SELECT pg_switch_wal();
    0/17000498
   ```

5. Восстановление выполнено в **отдельный кластер** (порт 5434) — рабочий кластер не затронут.

### 10.2. Команда восстановления

```bash
sudo pg_createcluster 18 pitr --port 5434          # конфигурация кластера
sudo pg_ctlcluster 18 pitr stop
sudo rm -rf /var/lib/postgresql/18/pitr
sudo install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/18/pitr

sudo -u postgres pgbackrest --stanza=lab \
    --pg1-path=/var/lib/postgresql/18/pitr \
    --type=time --target="2026-10-28 14:39:49" --target-action=promote \
    restore
```

```
INFO: repo1: restore backup set 20261028-143938F, recovery will start at 2026-10-28 14:39:38
INFO: remap data directory to '/var/lib/postgresql/18/pitr'
INFO: write updated /var/lib/postgresql/18/pitr/postgresql.auto.conf
INFO: restore global/pg_control (performed last to ensure aborted restores cannot be started)
INFO: restore size = 335.9MB, file total = 1286
INFO: restore command end: completed successfully (4992ms)
```

`--pg1-path` обязателен: иначе pgBackRest возьмёт путь primary из конфигурации
и откажется восстанавливать поверх работающего сервера (см. приложение Г).

### 10.3. Параметры восстановления

```
# /var/lib/postgresql/18/pitr/postgresql.auto.conf
restore_command = 'pgbackrest --pg1-path=/var/lib/postgresql/18/pitr --stanza=lab archive-get %f "%p"'
recovery_target_time = '2026-10-28 14:39:49'
recovery_target_action = 'promote'
```

### 10.4. Проигрывание WAL и результат

```
$ sudo pg_ctlcluster 18 pitr start

LOG:  database system is ready to accept read-only connections
LOG:  recovery stopping before commit of transaction 86027, time 2026-10-28 14:39:50.24466+00
LOG:  selected new timeline ID: 2
LOG:  database system is ready to accept connections
```

| Проверка | Восстановленный кластер (5434) | Рабочий primary (5432) |
|---|---|---|
| `pg_is_in_recovery()` | `f` (продвинут) | `f` |
| строк в `cluster_test` | **5** (id 1–5) | 6 |
| запись id=5 (`14:39:48`) | **есть** | есть |
| маркер id=6 (`14:39:50`) | **отсутствует** | есть |
| `pgbench_accounts` | 2 000 000 | 2 000 000 |
| timeline | 2 | 2 |

Восстановление остановилось ровно перед транзакцией маркера, автоматически продвинулось
(`target-action = promote`) и принимает соединения. Данные строго соответствуют целевой метке.

---

## 11. Этап 9. Тест на отказ (failover) и возврат узла

### 11.1. Имитация отказа primary

```bash
sudo pg_ctlcluster 18 main stop --force    # аварийная остановка, без checkpoint
```

```
$ pg_lsclusters
Ver Cluster Port Status Owner    Data directory                 Log file
18  main    5432 down   postgres /var/lib/postgresql/18/main    /var/log/postgresql/postgresql-18-main.log
18  pitr    5434 online postgres /var/lib/postgresql/18/pitr    /var/log/postgresql/postgresql-18-pitr.log
18  standby 5433 online postgres /var/lib/postgresql/18/standby /var/log/postgresql/postgresql-18-standby.log

=# SELECT pg_is_in_recovery();      -- 5433
 t
```

### 11.2. Продвижение реплики

```bash
sudo pg_ctlcluster 18 standby promote
```

```
LOG:  received promote request
LOG:  selected new timeline ID: 2
LOG:  database system is ready to accept connections
```

```
=# SELECT pg_is_in_recovery();                          -- 5433
 f

=# SELECT pg_walfile_name(pg_current_wal_lsn());
 000000020000000000000019

=# INSERT INTO cluster_test(note) VALUES ('запись на promoted-узле') RETURNING id;
 38

=# SELECT count(*) FROM cluster_test;
 7
```

Узел 5433 стал полноценным primary: принимает запись, WAL пишется в timeline 2.

### 11.3. Возврат старого primary в кластер

Старый primary (5432) после аварийной остановки не может просто «догнать» новый primary:
нужно выровнять каталог данных. Для этого в PostgreSQL есть `pg_rewind`
(в PPG 18 — `/usr/lib/postgresql/18/bin/pg_rewind`), он требует включённых контрольных сумм
страниц (`data_checksums = on`) или `wal_log_hints`.

В нашем прогоне реплика не отставала (все WAL были доставлены), поэтому расхождения данных
не возникло, и узел вернулся в строй как standby без `pg_rewind`:

```bash
sudo -u postgres tee /var/lib/postgresql/18/main/postgresql.auto.conf <<'EOF'
primary_conninfo = 'host=127.0.0.1 port=5433 user=replicator password=replpass application_name=replica2'
primary_slot_name = 'standby2_slot'
EOF

sudo -u postgres touch /var/lib/postgresql/18/main/standby.signal
sudo pg_ctlcluster 18 main start
```

```
LOG:  consistent recovery state reached at 0/190000A0
LOG:  database system is ready to accept read-only connections
LOG:  started streaming WAL from primary at 0/19000000
```

```
=# SELECT application_name, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;   -- 5433
 application_name |   state   | sync_state | sent_lsn  | replay_lsn
------------------+-----------+------------+-----------+------------
 replica2         | streaming | async      | 0/19000578 | 0/19000578

=# SELECT pg_is_in_recovery();      -- 5432
 t
```

Кластер снова состоит из двух узлов: 5433 — primary, 5432 — standby (`replica2`).
Данные на обоих узлах идентичны, включая запись, сделанную уже после promote.

**После демонстрации теста роли возвращены в исходное состояние:** узел 5432 продвинут обратно
(`pg_ctlcluster 18 main promote`, WAL перешёл на timeline 3), реплика 5433 пересобрана заново
`pg_basebackup -R -S replica_slot` и снова работает как standby с `application_name = replica`.
Параметры подключения к бывшему primary удалены из `postgresql.auto.conf`, кластер перезапущен
и проверен: `sent_lsn = replay_lsn`, запись с primary доходит до реплики.

---

## 12. Итоговые параметры кластера

```
=# SELECT name, setting, unit FROM pg_settings
   WHERE name IN ('shared_buffers','work_mem','effective_cache_size','maintenance_work_mem',
                  'wal_level','max_wal_senders','max_replication_slots','wal_keep_size',
                  'hot_standby','archive_mode','archive_command','shared_preload_libraries',
                  'synchronous_commit','data_checksums')
   ORDER BY name;
```

| Параметр | Значение |
|---|---|
| `shared_buffers` | 512 MB |
| `effective_cache_size` | 1536 MB |
| `work_mem` | 16 MB |
| `maintenance_work_mem` | 128 MB |
| `wal_level` | replica |
| `max_wal_senders` | 10 |
| `max_replication_slots` | 10 |
| `wal_keep_size` | 128 MB |
| `hot_standby` | on |
| `archive_mode` | on |
| `archive_command` | `pgbackrest --stanza=lab archive-push %p` |
| `shared_preload_libraries` | pgaudit, pg_stat_monitor |
| `synchronous_commit` | on (режим репликации — асинхронный) |
| `data_checksums` | on |

---

## 13. Выводы

1. Percona Distribution for PostgreSQL 18 установлен **нативно** в Ubuntu 24.04: пакеты
   из репозитория Percona, версия **PostgreSQL 18.6 / Percona Server for PostgreSQL 18.6.1**,
   управление через `pg_createcluster` / `pg_ctlcluster`, автозапуск через systemd.
2. Развёрнуты три независимых кластера: primary (5432), hot standby (5433) и восстановленная
   копия для PITR (5434) — конфигурация и данные разделены по каталогам Debian-раскладки.
3. Настроены параметры производительности и логирования, `pg_hba.conf` (scram-sha-256),
   роль `replicator`, база `appdb`, физический слот `replica_slot`.
4. Потоковая репликация работает: `state = streaming`, `sent_lsn = replay_lsn`, реплика
   принимает read-only запросы; проверен и синхронный режим (`sync_state = sync`).
5. Нагрузочные тесты pgbench: **1329.77** и **1512.07 tps** (OLTP, primary, 30 с),
   **39 716.32 tps** (SELECT-only на реплике) — без единой ошибки транзакции.
   Реплика разгружает primary по чтению в 26–30 раз.
6. Проверены компоненты Percona: pgaudit (аудит `write, ddl`, 340 974 записи за время тестов)
   и pg_stat_monitor (статистика запросов по корзинам времени).
7. Настроено резервное копирование pgBackRest: непрерывное архивирование WAL, полный бэкап
   `20261028-143938F` (335.9 MB → 21.2 MB, сжатие ~15.8×), репозиторий 37 MB.
8. Отработан PITR: из бэкапа развёрнут отдельный кластер, который воспроизвёл WAL из архива
   и остановился на метке `2026-10-28 14:39:49`; запись после метки отсутствует, инстанс
   автоматически продвинут, timeline 2.
9. Отработан отказ primary: реплика продвинута (`promote`), приняла запись, старый primary
   возвращён в кластер как standby (`replica2`), репликация восстановлена.
10. Кластер продолжает работать — можно продемонстрировать вживую; по ходу работы собраны
    типовые ошибки нативной эксплуатации и способы их устранения (приложение Г).

---

## Приложение А. Файлы проекта

```
postgres18-cluster/
├── README.md                        # этот отчёт
├── native/
│   ├── 01-install-percona.sh        # установка PPG 18 из репозитория
│   ├── 02-setup-primary.sh          # параметры, pg_hba, роль, слот, appdb
│   ├── 03-setup-standby.sh          # pg_createcluster + pg_basebackup + standby
│   ├── 04-check-replication.sh      # репликация, sync-режим, pgaudit, pg_stat_monitor
│   ├── 05-bench.sh                  # pgbench: OLTP на primary, SELECT на standby
│   ├── 06-backup.sh                 # pgBackRest: конфиг, stanza, полный бэкап
│   ├── 07-pitr.sh                   # восстановление на точку во времени
│   ├── 08-failover.sh               # отказ primary, promote, возврат узла
│   ├── configs/
│   │   ├── 90-lab-primary.conf      # conf.d для primary
│   │   ├── 90-lab-standby.conf      # conf.d для standby
│   │   └── pgbackrest.conf          # конфигурация pgBackRest
│   └── vm/
│       ├── create-vm.ps1            # создание ВМ Hyper-V + seed-диск cloud-init
│       ├── user-data                # cloud-init: пользователь, SSH-ключ
│       └── meta-data
└── .gitattributes
```

## Приложение Б. Порядок выполнения

| Шаг | Команда | Что делает |
|---|---|---|
| 1 | `./native/01-install-percona.sh` | репозиторий Percona + установка PPG 18 |
| 2 | `./native/02-setup-primary.sh` | настройка primary, роль, слот, appdb |
| 3 | `./native/03-setup-standby.sh` | standby через `pg_basebackup -R` |
| 4 | `./native/04-check-replication.sh` | проверка репликации, sync, аудит, мониторинг |
| 5 | `./native/05-bench.sh` | pgbench |
| 6 | `./native/06-backup.sh` | pgBackRest: stanza + полный бэкап |
| 7 | `./native/07-pitr.sh "YYYY-MM-DD HH:MM:SS"` | PITR в кластер на 5434 |
| 8 | `./native/08-failover.sh` | отказ primary и возврат узла |

## Приложение В. Полезные команды нативной эксплуатации

```bash
pg_lsclusters                       # список кластеров, порты, статус
pg_ctlcluster 18 main start|stop|restart|promote
pg_ctlcluster 18 standby promote    # превратить реплику в primary
pg_createcluster 18 <name> --port N
pg_dropcluster 18 <name>

sudo -u postgres psql -p 5433       # подключение к нужному кластеру
sudo tail -f /var/log/postgresql/postgresql-18-main.log

# резервное копирование
sudo -u postgres pgbackrest --stanza=lab check
sudo -u postgres pgbackrest --stanza=lab --type=full backup
sudo -u postgres pgbackrest --stanza=lab info

# восстановление (в отдельный каталог!)
sudo -u postgres pgbackrest --stanza=lab --pg1-path=/var/lib/postgresql/18/pitr \
    --type=time --target="2026-10-28 14:39:49" --target-action=promote restore
```

## Приложение Г. «Грабли» и решения

| Проблема | Симптом | Решение |
|---|---|---|
| `shared_preload_libraries` через `ALTER SYSTEM` | `FATAL: could not access file "..."` — в `postgresql.auto.conf` попало `'"pgaudit,pg_stat_monitor"'` | задавать список в конфигурационном файле (`conf.d/*.conf`), а не через `ALTER SYSTEM` |
| `primary_slot_name` внутри `primary_conninfo` | `FATAL: invalid connection string syntax: invalid connection option "primary_slot_name"` | это отдельный параметр: две строки в `postgresql.auto.conf` |
| `pg_createcluster` без `sudo` | `install: cannot change permissions of '/etc/postgresql/18/pitr'` | запускать от root (`sudo pg_createcluster ...`) |
| `pgbackrest restore` без `--pg1-path` | `ERROR: [038]: unable to restore while PostgreSQL is running` — берётся путь primary из конфига | указывать целевой каталог: `--pg1-path=/var/lib/postgresql/18/pitr` |
| `pg_rewind` не найден | `pg_rewind: command not found` | бинарник лежит в `/usr/lib/postgresql/18/bin/`, не в `PATH` |
| `rm -rf /var/lib/postgresql/18/standby/*` | «каталог не пуст»: glob не раскрывается из-под обычного пользователя (каталог 0700) | `sudo rm -rf <каталог> && sudo install -d -o postgres -g postgres -m 0700 <каталог>` |
| `--target-type=time` в pgBackRest | `ERROR: [031]: invalid option '--target-type=time'` | правильные опции: `--type=time --target="..." --target-action=promote` |
