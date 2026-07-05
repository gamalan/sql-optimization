# MySQL 8.0 Optimization Guide — Read/Write OLTP on Cloud VMs

**For:** Self-managed MySQL 8.0 with **primary + replicas** topology  
**Workload:** Mixed OLTP (web applications)  
**Deployment:** Cloud VMs (AWS EC2, GCP Compute Engine, etc.)

This guide covers the full stack: server config → replication → connection
pooling → read/write splitting → indexing → monitoring. Run the companion
audit script first:

```bash
./mysql-audit.sh -h <primary-host> -u root -r primary
./mysql-audit.sh -h <replica-host> -u root -r replica
```

---

## Table of Contents

1. [Server-Level Configuration](#1-server-level-configuration)
2. [Replication Architecture](#2-replication-architecture)
3. [Read/Write Splitting](#3-readwrite-splitting)
4. [Connection Pooling](#4-connection-pooling)
5. [Indexing Strategy](#5-indexing-strategy)
6. [Query Optimization](#6-query-optimization)
7. [SQLCommenter-Style Query Tagging](#7-sqlcommenter-style-query-tagging)
8. [Monitoring & Observability](#8-monitoring--observability)
9. [Backup & Recovery](#9-backup--recovery)
10. [PlanetScale-Inspired Practices (Adapted)](#10-planetscale-inspired-practices-adapted)
11. [Quick Reference Card](#11-quick-reference-card)

---

## 1. Server-Level Configuration

### 1.1 The Golden Formula: Memory Allocation

On a dedicated MySQL VM, allocate memory as follows:

```
Total RAM
├── 65%  → InnoDB Buffer Pool          (caches data + indexes)
├── 10%  → Connection buffers           (sort, join, read buffers × max_connections)
├── 15%  → OS page cache + binaries     (OS needs headroom)
└── 10%  → Other MySQL internals        (log buffer, AHI, dictionary, tmp tables)
```

**Quick Start Values (adjust to your VM size):**

| VM RAM  | innodb_buffer_pool_size | innodb_log_file_size | max_connections (with pool) |
|---------|------------------------|---------------------|----------------------------|
| 4 GB    | 2.5G                   | 512M                | 150                        |
| 8 GB    | 5G                     | 1G                  | 300                        |
| 16 GB   | 10G                    | 2G                  | 400                        |
| 32 GB   | 20G                    | 4G                  | 500                        |
| 64 GB   | 42G                    | 4G (max)            | 500                        |

### 1.2 InnoDB — The Heart of MySQL Performance

#### Buffer Pool (the single most important variable)

```ini
innodb_buffer_pool_size         = 10G    # 65% of RAM
innodb_buffer_pool_instances    = 8      # 1 per GB, max 8. Reduces contention.
```

- **Why it matters:** Every read and write touches the buffer pool. Too small
  = disk reads. Too large = OS swapping.
- **How to check:** `SHOW ENGINE INNODB STATUS\G` → look at "Buffer pool hit
  rate". Should be > 99%.

#### Redo Logs (write throughput)

```ini
innodb_log_file_size            = 2G     # ~25% of buffer pool, max 4G total
innodb_log_files_in_group       = 2
innodb_log_buffer_size          = 128M   # 64-256M for write-heavy
```

- **Larger log files** = better write throughput, but longer crash recovery.
- **Log buffer** = staging area before writing to disk. 64-256M.
- **Warning:** Changing `innodb_log_file_size` requires a clean shutdown +
  moving old log files. Plan downtime.

#### Durability vs. Speed

```ini
# Primary — full ACID (recommended)
innodb_flush_log_at_trx_commit  = 1
sync_binlog                     = 1

# Replica — fast (1 second of data loss acceptable)
innodb_flush_log_at_trx_commit  = 2
sync_binlog                     = 0
```

| Value | Behavior | Data Loss Risk | Use Case |
|-------|----------|---------------|----------|
| `flush=1, sync=1` | Flush on every commit | None | Primary (gold standard) |
| `flush=2, sync=0` | Flush every 1s to OS | 1 second | Replicas, staging |
| `flush=0, sync=0` | Flush every 1s (InnoDB) | 1 second | Bulk-load, replicas only |

#### IO Configuration (match your storage)

```ini
# NVMe SSD (AWS gp3, GCP SSD persistent)
innodb_io_capacity              = 4000
innodb_io_capacity_max          = 8000
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8

# SATA SSD (gp2, older cloud disks)
innodb_io_capacity              = 2000
innodb_io_capacity_max          = 4000
innodb_read_io_threads          = 4
innodb_write_io_threads         = 4

# Always on Linux
innodb_flush_method             = O_DIRECT    # Avoids double-buffering
```

#### Locking & Concurrency

```ini
innodb_thread_concurrency       = 0          # Let InnoDB auto-manage (best for 8.0)
innodb_lock_wait_timeout        = 10         # Fail fast on lock contention
innodb_deadlock_detect          = ON
innodb_autoinc_lock_mode        = 2          # Interleaved (fastest, default in 8.0)
```

### 1.3 Connection & Thread Tuning

```ini
max_connections                 = 400        # Cap at what your app pool uses × 1.5
thread_cache_size               = 200        # ~50% of max_connections
back_log                        = 500        # Queue for bursts
```

**Critical Warning:** Every connection consumes memory for session buffers:

```ini
sort_buffer_size                = 1M         # Per-connection! Keep small.
read_buffer_size                = 256K
read_rnd_buffer_size            = 512K
join_buffer_size                = 1M
```

`max_connections × (sum of buffers)` must fit within the ~10% RAM budget.
At 400 connections with 3MB/conn = 1.2GB. If you need more connections,
**use connection pooling**, not higher max_connections.

### 1.4 Table Caches

```ini
table_open_cache                = 4000
table_definition_cache          = 2000
table_open_cache_instances      = 16
```

Check `SHOW GLOBAL STATUS LIKE 'Opened_tables'`. If it's high relative to
uptime, increase `table_open_cache`.

### 1.5 Binary Log & GTID (Primary only)

```ini
log_bin                         = mysql-bin
binlog_format                   = ROW        # Required for GTID
sync_binlog                     = 1          # Durability
gtid_mode                       = ON
enforce_gtid_consistency        = ON
binlog_expire_logs_days         = 7
max_binlog_size                 = 512M
```

**Why GTID:** Makes failover deterministic. When you promote a replica to
primary, there's no ambiguity about replication position.

---

## 2. Replication Architecture

### 2.1 Recommended Topology

```
                   ┌──────────────┐
           ┌──────►│  Replica #1  │ (reads, reporting)
           │       └──────────────┘
┌──────────┤
│ Primary  │       ┌──────────────┐
│ (writes) ├──────►│  Replica #2  │ (reads, backups)
└──────────┘       └──────────────┘
```

### 2.2 Primary Configuration

```ini
# On every primary
server_id                       = 1          # Unique integer per server
log_bin                         = mysql-bin
binlog_format                   = ROW
gtid_mode                       = ON
enforce_gtid_consistency        = ON
binlog_row_image                = FULL

# For semi-synchronous replication (optional, reduces data loss)
# INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
# SET GLOBAL rpl_semi_sync_master_enabled = 1;
```

### 2.3 Replica Configuration

```ini
server_id                       = 2          # Unique per replica
read_only                       = ON         # CRITICAL: prevent accidental writes
super_read_only                 = ON         # Blocks SUPER-privilege writes too
gtid_mode                       = ON

# Parallel replication (significant performance boost)
slave_parallel_type             = LOGICAL_CLOCK
slave_parallel_workers          = 4          # 4-8 per replica
slave_preserve_commit_order     = ON

# Relax durability on replicas
innodb_flush_log_at_trx_commit  = 2
sync_binlog                     = 0          # Or keep ON if this replica might become primary
```

### 2.4 Replication Health Checks

```sql
-- On replica
SHOW SLAVE STATUS\G
-- Key fields: Slave_IO_Running, Slave_SQL_Running, Seconds_Behind_Master

-- On primary
SHOW SLAVE HOSTS;
SHOW MASTER STATUS;
```

**Alert thresholds:**

- `Seconds_Behind_Master > 5` → investigate
- `Slave_IO_Running != Yes` → network or binary log issue
- `Slave_SQL_Running != Yes` → query error on replica (check `Last_SQL_Error`)

### 2.5 Failover Procedure (GTID-based)

```sql
-- 1. On the replica to promote:
STOP SLAVE;
RESET SLAVE ALL;
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;

-- 2. On other replicas, point to the new primary:
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='<new-primary>', MASTER_AUTO_POSITION=1;
START SLAVE;
```

---

## 3. Read/Write Splitting

### 3.1 Application-Level Splitting (Recommended)

The simplest and most reliable approach:

```python
# Python pseudocode (SQLAlchemy example)
from sqlalchemy import create_engine
from sqlalchemy.orm import Session

write_engine = create_engine("mysql://user:pass@primary-host:3306/db")
read_engine  = create_engine("mysql://user:pass@replica-host:3306/db")

def get_user(user_id):
    with Session(read_engine) as session:           # READ → replica
        return session.execute(
            text("SELECT * FROM users WHERE id = :id"),
            {"id": user_id}
        ).first()

def create_user(name, email):
    with Session(write_engine) as session:          # WRITE → primary
        session.execute(
            text("INSERT INTO users (name, email) VALUES (:n, :e)"),
            {"n": name, "e": email}
        )
        session.commit()
```

**ORM integration:**

| ORM | Read/Write Splitting |
|-----|---------------------|
| **SQLAlchemy** | `Session(bind=read_engine)` vs `bind=write_engine`, or use `RoutingSession` |
| **Django** | `DATABASE_ROUTERS` + custom router class |
| **Rails/ActiveRecord** | `replica: true` in `database.yml` + `ApplicationRecord.connected_to(role: :reading)` |
| **Laravel/Eloquent** | `DB::connection('mysql_read')` + sticky connections |
| **HikariCP (Java)** | Multiple datasources with `@ReadOnlyDataSource` annotation |
| **Prisma (Node.js)** | `datasources.db_read` + `datasources.db_write` in schema |
| **GORM (Go)** | Separate `*gorm.DB` instances with write/replica plugins |

### 3.2 Middleware-Based Splitting (ProxySQL)

For applications that can't modify code easily, use **ProxySQL** as a
transparent read/write splitter:

```
                ┌──────────────┐
   App ───────►│   ProxySQL   │──────► Primary (writes)
                │ (port 6033)  │
                └──────┬───────┘
                       └──────────────► Replica #1 (reads)
                       └──────────────► Replica #2 (reads)
```

ProxySQL rules:

```sql
-- Route SELECT...FOR UPDATE to primary
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES (1, 1, '^SELECT.*FOR UPDATE', 0, 1);

-- Route SELECT to replicas
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES (2, 1, '^SELECT', 1, 1);

-- Everything else (INSERT, UPDATE, DELETE) to primary
INSERT INTO mysql_query_rules (rule_id, active, match_pattern, destination_hostgroup, apply)
VALUES (3, 1, '.*', 0, 1);
```

### 3.3 Read-Your-Own-Writes

The classic "replication lag" problem: you write on the primary, immediately
read from a replica, and the data isn't there yet.

**Solutions:**

1. **Sticky connections:** After a write, route subsequent reads from the
   same user to the primary for N seconds.

2. **Write-through cache:** Write to Redis → confirm cache → write to MySQL.
   Reads hit Redis first.

3. **GTID-based consistency:** After a write, capture `@@gtid_executed`,
   then wait on replica with `WAIT_FOR_EXECUTED_GTID_SET()`. Use sparingly
   (adds latency).

4. **Application design:** Where possible, return the written object in the
   write response. The user sees their own write from the response, not
   from a subsequent read.

```python
# Example: Read-your-own-writes with sticky connection
def create_post(user_id, content):
    # Write to primary
    post = write_db.insert_post(user_id, content)
    # Set a cookie/session flag: "user_just_wrote = true"
    return post  # Return full post from the INSERT response

def get_posts(user_id):
    if session.get("user_just_wrote", False):
        posts = write_db.get_posts(user_id)   # Use primary
    else:
        posts = read_db.get_posts(user_id)     # Use replica
```

---

## 4. Connection Pooling

### 4.1 Why Pooling Matters

MySQL connections are expensive (~256KB+ thread stack + session buffers).
Without pooling:

- Each HTTP request → new MySQL connection → slow
- 1000 concurrent requests × 3MB/conn = **3GB RAM** just for idle connections
- Connection churn triggers thread creation/destruction overhead

### 4.2 Pool Sizing Formula

```
pool_size = (CPU_cores * 2) to (CPU_cores * 4)

For a 4-core VM: 8-16 connections per pool
For an 8-core VM: 16-32 connections per pool
```

**Do NOT** size pools to `max_connections`. If you need 1000 concurrent DB
operations, queue them — don't open 1000 connections.

### 4.3 Pool Configurations

| Pool | Config |
|------|--------|
| **HikariCP (Java)** | `maximumPoolSize=20`, `minimumIdle=10`, `connectionTimeout=30000` |
| **SQLAlchemy (Python)** | `pool_size=20`, `max_overflow=10`, `pool_recycle=3600` |
| **Prisma (Node.js)** | `connection_limit=20`, `pool_timeout=10` |
| **GORM (Go)** | `SetMaxOpenConns(25)`, `SetMaxIdleConns(10)`, `SetConnMaxLifetime(1h)` |
| **ProxySQL (middleware)** | `mysql-default_max_latency_ms=1000`, connection multiplexing ON |
| **PgBouncer (Postgres)** | Not for MySQL — use ProxySQL or MySQL Router |

### 4.4 Pool Sizing for Read/Write Split

```
Write pool (primary):  pool_size = 10-20   (tight — writes are serialized anyway)
Read pool (replica):   pool_size = 20-50   (more — reads parallelize well)
```

### 4.5 Connection Validation

Always test connections before use. Pools hold idle connections that may
have been killed by `wait_timeout`:

```python
# SQLAlchemy
engine = create_engine(url, pool_pre_ping=True)

# HikariCP
# connectionTestQuery=SELECT 1
# validationTimeout=5000
```

---

## 5. Indexing Strategy

### 5.1 Index Types and When to Use

| Index Type | MySQL 8.0 | Best For |
|-----------|-----------|----------|
| **B-Tree** (default) | ✓ | Equality, range, ORDER BY, GROUP BY |
| **Fulltext** | ✓ | Text search (LIKE '%word%' is too slow) |
| **Spatial (R-Tree)** | ✓ | Geospatial queries |
| **Descending** | ✓ 8.0+ | Mixed ASC/DESC ORDER BY |
| **Invisible** | ✓ 8.0+ | Test index removal safely before dropping |
| **Functional** | ✓ 8.0.13+ | Index on expressions: `INDEX((YEAR(date_col)))` |
| **Multi-valued** | ✓ 8.0.17+ | Index JSON arrays |
| **Prefix** | ✓ | Index first N chars of TEXT/BLOB |

### 5.2 Composite Index Rules

```
Columns in ORDER:
  1. Equality conditions    (WHERE status = 'active')
  2. Range conditions       (WHERE created_at > '2024-01-01')
  3. GROUP BY columns
  4. ORDER BY columns
  5. SELECT columns         (covering index)

Example: INDEX(status, created_at, user_id)
         WHERE status = ? AND created_at > ? ORDER BY user_id
```

### 5.3 Finding Missing & Unused Indexes

```sql
-- Missing indexes: queries doing full table scans
SELECT * FROM sys.schema_tables_with_full_table_scans;

-- Unused indexes: indexes that exist but never helped
SELECT * FROM sys.schema_unused_indexes;

-- Redundant indexes: indexes that are prefixes of others
SELECT * FROM sys.schema_redundant_indexes;

-- Indexes that could be improved (cardinality issues)
SELECT * FROM sys.schema_index_statistics
WHERE rows_selected > 0 AND rows_selected > rows_inserted * 10;
```

### 5.4 Indexing for Common OLTP Patterns

```sql
-- Pagination (cursor-based, not OFFSET)
-- Bad:  SELECT * FROM posts ORDER BY id LIMIT 20 OFFSET 100000;
-- Good: SELECT * FROM posts WHERE id > :last_id ORDER BY id LIMIT 20;
-- Index: PRIMARY KEY (id) — already covered

-- User-scoped queries
-- Query: SELECT * FROM orders WHERE user_id = ? AND status = ?
-- Index: INDEX idx_user_status (user_id, status)

-- Soft deletes
-- Query: SELECT * FROM posts WHERE deleted_at IS NULL ORDER BY created_at DESC
-- Index: INDEX idx_active_posts (deleted_at, created_at)

-- Counter/aggregation queries
-- Query: SELECT COUNT(*) FROM events WHERE type = ? AND created_at > ?
-- Index: INDEX idx_event_type_date (type, created_at)

-- JOIN with filtering
-- Query: SELECT u.* FROM users u JOIN orders o ON u.id = o.user_id WHERE o.status = ?
-- Index: INDEX idx_orders_status_user (status, user_id)  -- on orders
--         PRIMARY KEY (id)                                -- on users (already exists)
```

### 5.5 Index Maintenance

```sql
-- Rebuild statistics weekly (during low traffic)
ANALYZE TABLE users, orders, products;

-- Check fragmentation
SELECT TABLE_NAME, DATA_FREE / 1024 / 1024 AS fragment_mb
FROM information_schema.TABLES
WHERE DATA_FREE > 100 * 1024 * 1024  -- >100MB fragmented
ORDER BY fragment_mb DESC;

-- Rebuild fragmented tables (careful — locks the table!)
-- Use pt-online-schema-change or gh-ost for zero-downtime:
-- pt-online-schema-change --alter "ENGINE=InnoDB" D=db,t=table
```

### 5.6 Indexing Do's and Don'ts

**Do:**

- ✓ Index foreign key columns
- ✓ Use covering indexes (all selected columns in the index) for hot queries
- ✓ Test with EXPLAIN before deploying
- ✓ Use invisible indexes to test removal

**Don't:**

- ✗ Index every column (slows writes)
- ✗ Use `LIKE '%pattern'` (leading wildcard = no index use)
- ✗ Use functions on indexed columns in WHERE: `WHERE YEAR(date) = 2024`
- ✗ Index low-cardinality columns alone (status, boolean)
- ✗ Forget to index JOIN columns

---

## 6. Query Optimization

### 6.1 The EXPLAIN Hierarchy

```sql
-- Always run EXPLAIN before deploying queries
EXPLAIN FORMAT=TREE SELECT ...    -- Clean hierarchy view (8.0.16+)
EXPLAIN ANALYZE SELECT ...        -- Actual execution stats (8.0.18+)
EXPLAIN FORMAT=JSON SELECT ...    -- Machine-parseable detail
```

**What to look for:**

| Problem | EXPLAIN Signal |
|---------|---------------|
| Full table scan | `type: ALL` (on large tables) |
| Missing index | `rows: 1000000` vs `filtered: 1.00` |
| Bad JOIN order | Large `rows` × many iterations |
| Filesort | `Extra: Using filesort` (sorting without index) |
| Temp table | `Extra: Using temporary` |
| Index not used | `possible_keys: idx_x` but `key: NULL` |
| Too many rows examined | `rows_examined_per_scan` >> `rows_produced_per_join` |

### 6.2 Common Optimization Patterns

#### N+1 Queries → Batch Loading

```sql
-- N+1 Problem (in application code)
for user in users:
    orders = db.query("SELECT * FROM orders WHERE user_id = ?", user.id)
    # 1 + N queries!

-- Solution: Batch load
SELECT * FROM users WHERE id IN (1,2,3,...);
SELECT * FROM orders WHERE user_id IN (1,2,3,...);
-- OR: SELECT u.*, o.* FROM users u LEFT JOIN orders o ON u.id = o.user_id
--      WHERE u.id IN (1,2,3,...);
```

#### OFFSET Pagination → Cursor Pagination

```sql
-- Slow (scans all skipped rows)
SELECT * FROM posts ORDER BY id DESC LIMIT 20 OFFSET 100000;

-- Fast (uses index directly)
SELECT * FROM posts WHERE id < :last_seen_id ORDER BY id DESC LIMIT 20;
```

#### COUNT(*) → Approximate

```sql
-- Slow on large tables
SELECT COUNT(*) FROM events WHERE created_at > '2024-01-01';

-- Fast estimate (from stats)
SELECT TABLE_ROWS FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'mydb' AND TABLE_NAME = 'events';

-- Or maintain a counter table for exact counts
-- UPDATE counter SET count = count + 1 WHERE entity = 'events' AND date = CURDATE();
```

#### OR Conditions → UNION

```sql
-- Slow (often can't use indexes well)
SELECT * FROM users WHERE email = ? OR username = ?;

-- Fast (each branch uses its index)
SELECT * FROM users WHERE email = ?
UNION ALL
SELECT * FROM users WHERE username = ?;
```

#### DISTINCT + ORDER BY → GROUP BY

```sql
-- Often slower
SELECT DISTINCT category FROM products ORDER BY category;

-- Often faster (uses index)
SELECT category FROM products GROUP BY category ORDER BY category;
```

### 6.3 Avoiding Query Mistakes

```sql
-- ✗ Bad: Function on indexed column
SELECT * FROM orders WHERE DATE(created_at) = '2024-01-15';
-- ✓ Good: Range condition
SELECT * FROM orders WHERE created_at >= '2024-01-15'
                        AND created_at < '2024-01-16';

-- ✗ Bad: Negative condition
SELECT * FROM users WHERE status != 'deleted';
-- ✓ Good: Positive condition (if most users are active)
-- Or use a composite index with status as the first column

-- ✗ Bad: IN with huge lists
SELECT * FROM users WHERE id IN (1, 2, 3, ..., 50000);
-- ✓ Good: JOIN to a temp table or break into batches

-- ✗ Bad: Leading wildcard
SELECT * FROM posts WHERE title LIKE '%optimization';
-- ✓ Good: Fulltext index or store reversed string
```

---

## 7. SQLCommenter-Style Query Tagging

SQLCommenter is a standard for embedding metadata in SQL comments. It was
popularized by Google/PlanetScale and is invaluable for tracing query
performance back to application code.

### 7.1 Tag Format

```sql
SELECT /* application=myapp,controller=users,action=show,route=/users/:id,source=app */
    id, name, email
FROM users
WHERE id = 123;
```

### 7.2 Recommended Tag Schema

| Tag | Example | Cardinality | Notes |
|-----|---------|------------|-------|
| `application` | `myapp` | Low (1) | App name, never changes |
| `service` | `api`, `worker` | Low (2-5) | Service/process name |
| `environment` | `production` | Low (1-3) | production, staging, dev |
| `route` | `/users/:id` | Medium | Normalized route template |
| `controller` | `UsersController` | Medium | MVC controller |
| `action` | `show` | Medium | Controller action |
| `job` | `SendEmailJob` | Medium | Background job class |
| `queue` | `default` | Low | Background queue name |
| `feature` | `search` | Low (3-10) | Feature area |
| `release_sha` | `abc1234` | High (rotating) | Git SHA, identifiable |
| `source` | `app` | Low (3-5) | app, worker, script, agent, bi |
| `tenant_tier` | `enterprise` | Low (2-5) | Bounded tenant grouping |

**Do NOT tag:**

- ✗ `user_id` / `request_id` / `tenant_id` (unbounded cardinality, PII)
- ✗ `email` / `session_id` / `access_token` (PII, security risk)
- ✗ Raw URLs with IDs (`/users/123/orders`)
- ✗ Unbounded GraphQL operation text

### 7.3 Framework Integration

**Rails (ActiveRecord):**

```ruby
# config/initializers/sqlcommenter.rb
require 'marginalia'
Marginalia::Comment.components = [:application, :controller, :action]

# Gemfile
# gem 'marginalia'
```

**Django (Python):**

```python
# settings.py
SQLCOMMENTER_WITH_FRAMEWORK = True

# Or manual middleware
class SqlcommenterMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        sql_comment = f"route={request.resolver_match.route}"
        request.sqlcommenter_meta = sql_comment
        return self.get_response(request)
```

**Express (Node.js):**

```javascript
// middleware/sqlcommenter.js
app.use((req, res, next) => {
  const route = req.route ? req.route.path : req.path;
  res.locals.sqlcommenter = `application=myapp,route=${route}`;
  next();
});

// In your query wrapper
const comment = res.locals.sqlcommenter || '';
db.query(`SELECT /* ${comment} */ * FROM users WHERE id = ?`, [id]);
```

### 7.4 Analyzing Tagged Queries

```sql
-- Top routes by query time (from slow query log)
SELECT
    SUBSTRING_INDEX(SUBSTRING_INDEX(query_text, 'route=', -1), ',', 1) AS route,
    COUNT(*) AS query_count,
    ROUND(AVG(query_time), 4) AS avg_time_sec,
    ROUND(SUM(query_time), 2) AS total_time_sec
FROM mysql.slow_log
WHERE query_text LIKE '%route=%'
GROUP BY route
ORDER BY total_time_sec DESC;

-- Untagged queries (coverage gap)
SELECT COUNT(*) AS untagged_count
FROM mysql.slow_log
WHERE query_text NOT LIKE '%application=%'
  AND query_text NOT LIKE '%route=%';
```

---

## 8. Monitoring & Observability

### 8.1 Essential Metrics

#### Server-Level (collect every 10-30s)

| Metric | Source | Alert Threshold |
|--------|--------|----------------|
| **CPU utilization** | OS | > 80% sustained |
| **Memory usage** | OS | > 90% (swap risk) |
| **Disk IOPS/latency** | OS / `iostat` | await > 10ms |
| **Disk space** | OS | < 20% free |
| **Network throughput** | OS | Near bandwidth limit |

#### MySQL-Level

| Metric | Query | Healthy Range |
|--------|-------|--------------|
| Buffer pool hit rate | `SHOW ENGINE INNODB STATUS` | > 99% |
| Connections used / max | `SHOW STATUS LIKE 'Threads_connected'` | < 80% of max |
| Slow queries / sec | `SHOW STATUS LIKE 'Slow_queries'` | Near 0 |
| Aborted connections | `SHOW STATUS LIKE 'Aborted_connects'` | Near 0 |
| Table lock waits | `SHOW STATUS LIKE 'Table_locks_waited'` | < 10% of immediate |
| Replication lag | `SHOW SLAVE STATUS` → `Seconds_Behind_Master` | < 1s |
| InnoDB row lock waits | `SHOW STATUS LIKE 'Innodb_row_lock_waits'` | Near 0 |
| Created tmp disk tables | `SHOW STATUS LIKE 'Created_tmp_disk_tables'` | < 25% of total |
| Open files | `SHOW STATUS LIKE 'Open_files'` | < 80% of `open_files_limit` |
| Binlog disk usage | OS `du` | Watch growth rate |

### 8.2 Query-Level Monitoring

```sql
-- Top 10 queries by total execution time (Performance Schema)
SELECT
    LEFT(DIGEST_TEXT, 120) AS query,
    COUNT_STAR AS exec_count,
    ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS avg_ms,
    ROUND(SUM_TIMER_WAIT / 1000000000, 2) AS total_ms,
    ROUND(SUM_ROWS_EXAMINED / COUNT_STAR, 0) AS avg_rows_examined,
    ROUND(SUM_ROWS_SENT / COUNT_STAR, 0) AS avg_rows_sent
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT IS NOT NULL
  AND SCHEMA_NAME IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 10;

-- Queries with full table scans on large tables
SELECT
    DIGEST_TEXT,
    COUNT_STAR,
    SUM_NO_INDEX_USED,
    SUM_NO_GOOD_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
WHERE SUM_NO_INDEX_USED > 0 OR SUM_NO_GOOD_INDEX_USED > 0
ORDER BY SUM_NO_INDEX_USED DESC
LIMIT 10;
```

### 8.3 Tooling

| Tool | What It Does | Setup Effort |
|------|-------------|-------------|
| **Percona PMM** | Full observability suite (dashboards, query analytics, alerts) | Medium |
| **pt-query-digest** | Slow query log analysis | Low |
| **Netdata** | Real-time system + MySQL metrics | Low |
| **Datadog MySQL** | Managed monitoring with APM integration | Low (paid) |
| **Prometheus + Grafana** | Self-hosted metrics pipeline | High |
| **mytop / innotop** | Real-time process list viewer | Low |

### 8.4 Quick Health Check Script

```sql
-- Run this for a 30-second health snapshot
SELECT 'Buffer Pool Hit Rate' AS metric,
       ROUND((1 - (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') /
                  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                   WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests' + 1)) * 100, 2) AS value
UNION ALL
SELECT 'Thread Cache Hit Rate',
       ROUND((1 - (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                   WHERE VARIABLE_NAME = 'Threads_created') /
                  (SELECT VARIABLE_VALUE FROM performance_schema.global_status
                   WHERE VARIABLE_NAME = 'Connections' + 1)) * 100, 2)
UNION ALL
SELECT 'Tmp Table Disk Ratio',
       ROUND((SELECT VARIABLE_VALUE FROM performance_schema.global_status
              WHERE VARIABLE_NAME = 'Created_tmp_disk_tables') /
             (SELECT VARIABLE_VALUE FROM performance_schema.global_status
              WHERE VARIABLE_NAME = 'Created_tmp_tables' + 1) * 100, 2)
UNION ALL
SELECT 'Active Connections',
       (SELECT COUNT(*) FROM performance_schema.processlist
        WHERE USER != 'system user');
```

---

## 9. Backup & Recovery

### 9.1 Backup Strategy

| Type | Tool | Frequency | Retention |
|------|------|-----------|-----------|
| **Full hot backup** | Percona XtraBackup | Daily | 7 days |
| **Incremental** | Percona XtraBackup | Hourly | 24 hours |
| **Binary logs** | Built-in (continuous) | Real-time | 2 days (for PITR) |
| **Logical dump** | `mysqldump --single-transaction` | Weekly | 30 days |

### 9.2 Percona XtraBackup

```bash
# Full backup
xtrabackup --backup \
    --host=127.0.0.1 --user=backup --password=... \
    --target-dir=/backups/full/$(date +%Y%m%d) \
    --compress --parallel=4

# Prepare (make consistent — run before restore)
xtrabackup --prepare --target-dir=/backups/full/20240101/

# Incremental (based on full)
xtrabackup --backup \
    --target-dir=/backups/inc/$(date +%Y%m%d_%H%M) \
    --incremental-basedir=/backups/full/20240101/

# Restore
systemctl stop mysql
rm -rf /var/lib/mysql/*
xtrabackup --copy-back --target-dir=/backups/full/20240101/
chown -R mysql:mysql /var/lib/mysql
systemctl start mysql
```

### 9.3 Point-in-Time Recovery

```sql
-- 1. Restore full backup
-- 2. Apply binary logs up to the desired point
mysqlbinlog --start-datetime="2024-01-15 14:00:00" \
            --stop-datetime="2024-01-15 14:05:00" \
            mysql-bin.000123 | mysql -u root -p

-- Or use GTID for precision
mysqlbinlog --include-gtids='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:1-5000' \
            mysql-bin.000123 | mysql -u root -p
```

### 9.4 Backup Verification

**Always test your backups!** Run a restore drill monthly:

```bash
# Spin up a test instance
docker run --name mysql-restore-test \
    -e MYSQL_ROOT_PASSWORD=test \
    -v /backups/full/20240101:/backup \
    -d mysql:8.0

# Restore and verify
docker exec mysql-restore-test /backup/restore.sh
docker exec mysql-restore-test mysql -u root -ptest \
    -e "SELECT COUNT(*) FROM mydb.users;"
```

---

## 10. PlanetScale-Inspired Practices (Adapted)

While you're not on PlanetScale, their engineering insights are valuable.
Here's how to adapt them for self-managed MySQL:

### 10.1 Schema Change Workflow (Safe Migrations)

PlanetScale uses non-blocking schema changes. You can achieve similar safety
with **gh-ost** or **pt-online-schema-change**:

```bash
# Using gh-ost (GitHub's online schema migration tool)
gh-ost \
    --host=primary-host \
    --user=admin --password=... \
    --database=mydb --table=users \
    --alter="ADD COLUMN last_login_at DATETIME NULL" \
    --chunk-size=1000 \
    --max-load=Threads_running=30 \
    --critical-load=Threads_running=100 \
    --cut-over=default \
    --execute

# Using pt-online-schema-change (Percona)
pt-online-schema-change \
    --alter="ADD INDEX idx_email (email)" \
    --max-load="Threads_running=50" \
    --critical-load="Threads_running=100" \
    --chunk-size=2000 \
    --execute \
    D=mydb,t=users,h=primary-host
```

**Migration workflow:**

1. Test migration on a staging replica
2. Apply via gh-ost/pt-osc (zero downtime)
3. Monitor replication lag during migration
4. Verify with `SHOW CREATE TABLE` after completion
5. Keep the gh-ost ghost table (`_tablename_gho`) around for 24h for rollback

### 10.2 Query Tagging (SQLCommenter)

Already covered in Section 7. PlanetScale uses tags to attribute load to
specific routes and features. You can achieve the same with MySQL's
Performance Schema and slow query log analysis.

### 10.3 "Deploy Request" — Reviewable Schema Changes

PlanetScale has a review workflow for schema changes. Implement manually:

```
1. Developer creates migration PR
2. PR includes:
   - Migration SQL
   - EXPLAIN output for new indexes
   - Expected impact (rows affected, index size)
   - Rollback SQL
3. Reviewer checks:
   - Is the index needed? (EXPLAIN evidence)
   - Is there a redundant index to remove?
   - Will it block writes? (use gh-ost, don't block)
   - Is rollback documented?
4. Apply via gh-ost/pt-osc (not raw ALTER TABLE)
5. Verify and close PR
```

### 10.4 "Insights" — Query Performance Analysis (DIY)

PlanetScale's Insights maps queries to code. DIY version:

```bash
# 1. Collect slow query log with tags
# 2. Analyze with pt-query-digest
pt-query-digest /var/log/mysql/mysql-slow.log \
    --filter '$event->{arg} =~ m/route=/i' \
    --report-format=query_report \
    --limit=20

# 3. Parse tags to group by route/controller
grep -oP 'route=\K[^,]+' /var/log/mysql/mysql-slow.log \
    | sort | uniq -c | sort -rn | head -20
```

### 10.5 Resource Groups (MySQL 8.0)

MySQL 8.0's Resource Groups are the self-managed equivalent of PlanetScale's
Traffic Control. Isolate heavy queries from critical OLTP:

```sql
-- Enable resource groups
SET GLOBAL resource_group_enabled = ON;

-- Create resource groups
CREATE RESOURCE GROUP rg_oltp    TYPE=USER VCPU=0-3 THREAD_PRIORITY=10;
CREATE RESOURCE GROUP rg_reports TYPE=USER VCPU=4-7 THREAD_PRIORITY=5;
CREATE RESOURCE GROUP rg_batch   TYPE=USER VCPU=4-7 THREAD_PRIORITY=2;

-- Route connections to groups
SET RESOURCE GROUP rg_oltp;     -- Fast OLTP queries

-- In your app: reporting connections
-- SET RESOURCE GROUP rg_reports;
-- SELECT * FROM huge_report_table WHERE ...

-- In your app: batch job connections
-- SET RESOURCE GROUP rg_batch;
```

### 10.6 Branching Strategy (DIY Equivalent)

PlanetScale creates database branches. Self-managed equivalent:

```
Primary (production) → Replica (staging/clone for testing)

To create a "branch":
  # Option A: Clone from backup
  xtrabackup --backup --target-dir=/tmp/clone
  xtrabackup --prepare --target-dir=/tmp/clone
  # Start new MySQL on the cloned data

  # Option B: Use a replica stopped at a point in time
  STOP SLAVE;
  SHOW SLAVE STATUS;    # Note the GTID position
  # Clone/replicate this stopped replica for testing
```

---

## 11. Quick Reference Card

### Critical Variables Cheatsheet

```ini
# ── MUST SET ──
innodb_buffer_pool_size         = <65% of RAM>
innodb_log_file_size            = <25% of buffer pool, max 4G>
innodb_flush_method             = O_DIRECT
innodb_flush_log_at_trx_commit  = 1           # 2 on replicas
sync_binlog                     = 1           # 0 on replicas
binlog_format                   = ROW
gtid_mode                       = ON

# ── SHOULD SET ──
innodb_buffer_pool_instances    = 8
innodb_io_capacity              = 2000-4000
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8
max_connections                 = <pool size × 2>
thread_cache_size               = <max_connections / 2>
table_open_cache                = 4000
read_only                       = ON         # replicas only
super_read_only                 = ON         # replicas only
slave_parallel_workers          = 4-8        # replicas only

# ── SESSION BUFFERS (keep small) ──
sort_buffer_size                = 1M
join_buffer_size                = 1M
read_buffer_size                = 256K
tmp_table_size                  = 32M
max_heap_table_size             = 32M

# ── LOGGING ──
slow_query_log                  = ON
long_query_time                 = 0.5
performance_schema              = ON
```

### Operational Checklist

```
Daily:
  □ Check replication lag (Seconds_Behind_Master < 1)
  □ Check disk space (> 20% free)
  □ Verify backups completed
  □ Review slow query log top entries

Weekly:
  □ ANALYZE TABLE on hot tables
  □ Check unused indexes (sys.schema_unused_indexes)
  □ Review connection pool metrics
  □ Check binary log disk usage

Monthly:
  □ Full backup restore drill
  □ Review and update MySQL config
  □ Check for MySQL 8.0 minor version updates
  □ Audit user permissions
  □ Check table fragmentation
```

### Troubleshooting Flow

```
Symptom: High CPU
  → Check slow query log → Add indexes → Cache hot data
  → Check for full table scans → EXPLAIN → fix queries

Symptom: High IO wait
  → Check buffer pool hit rate → increase innodb_buffer_pool_size
  → Check innodb_io_capacity → match storage speed
  → Check tmp_table_size → reduce Created_tmp_disk_tables

Symptom: Replication lag
  → Check slave_parallel_workers → increase to 4-8
  → Check for long-running writes → batch/chunk them
  → Check replica hardware matches primary

Symptom: Connection timeouts
  → Check max_connections vs pool size
  → Check wait_timeout vs pool idle timeout
  → Check for connection leaks (idle in transaction)

Symptom: Slow writes
  → Check innodb_flush_log_at_trx_commit → consider 2 (with trade-off)
  → Check sync_binlog → consider 0 on replicas
  → Increase innodb_log_file_size
  → Batch INSERT into transactions
```

---

## Appendix A: Connection Pool Configuration Examples

### HikariCP (Java / Spring Boot)

```yaml
# application.yml
spring:
  datasource:
    # Write (primary)
    write:
      jdbc-url: jdbc:mysql://primary:3306/mydb
      username: app
      password: ${DB_PASSWORD}
      hikari:
        maximum-pool-size: 20
        minimum-idle: 10
        idle-timeout: 600000
        max-lifetime: 1800000
        connection-timeout: 30000
        connection-test-query: SELECT 1

    # Read (replica)
    read:
      jdbc-url: jdbc:mysql://replica:3306/mydb
      username: app_readonly
      password: ${DB_READ_PASSWORD}
      hikari:
        maximum-pool-size: 40
        minimum-idle: 20
```

### SQLAlchemy (Python)

```python
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

# Engines
write_engine = create_engine(
    "mysql+mysqldb://user:pass@primary/mydb",
    pool_size=20,
    max_overflow=10,
    pool_recycle=3600,
    pool_pre_ping=True,
)

read_engine = create_engine(
    "mysql+mysqldb://user:pass@replica/mydb",
    pool_size=40,
    max_overflow=20,
    pool_recycle=3600,
    pool_pre_ping=True,
)

# Factories
WriteSession = sessionmaker(bind=write_engine)
ReadSession = sessionmaker(bind=read_engine)

# Usage
def get_user(user_id):
    with ReadSession() as session:
        return session.get(User, user_id)

def create_user(name, email):
    with WriteSession() as session:
        user = User(name=name, email=email)
        session.add(user)
        session.commit()
        return user
```

---

## Appendix B: Sample Docker Compose for Testing

```yaml
# docker-compose.yml — For testing configurations locally
version: '3.8'
services:
  mysql-primary:
    image: mysql:8.0
    container_name: mysql-primary
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: mydb
    ports:
      - "3306:3306"
    volumes:
      - ./primary.cnf:/etc/mysql/conf.d/custom.cnf
      - primary_data:/var/lib/mysql
    command: >
      --server-id=1
      --log-bin=mysql-bin
      --gtid-mode=ON
      --enforce-gtid-consistency=ON

  mysql-replica:
    image: mysql:8.0
    container_name: mysql-replica
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
    ports:
      - "3307:3306"
    volumes:
      - ./replica.cnf:/etc/mysql/conf.d/custom.cnf
      - replica_data:/var/lib/mysql
    command: >
      --server-id=2
      --read-only=ON
      --super-read-only=ON
      --gtid-mode=ON
      --enforce-gtid-consistency=ON
    depends_on:
      - mysql-primary

volumes:
  primary_data:
  replica_data:
```

---

*Guide generated for self-managed MySQL 8.0 on cloud VMs. Companion script:
`mysql-audit.sh`. Adapt values to your hardware and workload.*
