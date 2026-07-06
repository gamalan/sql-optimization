# PostgreSQL-Specific Slow Query Patterns

These patterns are **additive** to the framework-specific patterns
(`laravel.md`, `django.md`, etc.). PostgreSQL has unique capabilities and
anti-patterns that don't exist in MySQL or SQLite.

## Database-Specific Anti-Patterns

---

## Pattern PG-1: CTE as Optimization Fence (CTE Materialization)

**SQL Signature:**

```sql
WITH cte AS (
    SELECT * FROM large_table WHERE condition
)
SELECT * FROM cte WHERE other_condition;
```

**What's Wrong:**

Before PostgreSQL 12, CTEs were always materialized (optimization fence).
The outer WHERE cannot be pushed into the CTE, causing full scans. Even in
PG 12+ with `MATERIALIZED` / `NOT MATERIALIZED`, the default is
`MATERIALIZED` for CTEs referenced multiple times.

**Fix:**

```sql
-- ✅ Use NOT MATERIALIZED if the CTE is simple and referenced once
WITH cte AS NOT MATERIALIZED (
    SELECT * FROM large_table WHERE condition
)
SELECT * FROM cte WHERE other_condition;

-- ✅ Or just use a subquery (always merged)
SELECT * FROM (
    SELECT * FROM large_table WHERE condition
) sub WHERE other_condition;
```

**Detection:**

- `WITH ... AS (` in fingerprint
- CTE selects from a large table but outer query has additional filters
- `EXPLAIN` shows `CTE Scan` with high row estimates

**Severity:** 🟠 High (for large tables)

---

## Pattern PG-2: Missing BRIN Index for Large Append-Only Tables

**SQL Signature:**

```sql
SELECT * FROM events WHERE created_at BETWEEN '2024-01-01' AND '2024-01-31'
-- Table has billions of rows, sequentially inserted
```

**What's Wrong:**

B-tree indexes on monotonically increasing columns (timestamps, IDs) grow
large on append-only tables. BRIN (Block Range INdex) is 100-1000x smaller
and sufficient for range queries on naturally ordered data.

**Fix:**

```sql
-- ✅ BRIN index (tiny, fast to create, good for correlated data)
CREATE INDEX idx_events_created_brin ON events USING BRIN (created_at)
    WITH (pages_per_range = 32);

-- ✅ Or btree for precise lookups
CREATE INDEX idx_events_created_btree ON events (created_at);
```

**When to use BRIN vs B-tree:**

| Factor | BRIN | B-tree |
|--------|------|--------|
| Size | ~0.1% of table | ~2-5% of table |
| Creation time | Seconds | Minutes/hours |
| Point lookup speed | Slower | Fast |
| Range scan speed | Good (if correlated) | Good |
| Best for | Append-only, naturally ordered | Random access, point queries |

**Detection:**

- Tables > 100M rows with timestamps or serial IDs
- `WHERE created_at BETWEEN` or `WHERE id > ?` patterns
- No index or only a massive btree index

**Severity:** 🟡 Medium (space + creation time savings)

---

## Pattern PG-3: Not Using Partial Indexes

**SQL Signature:**

```sql
SELECT * FROM orders WHERE status = 'active' AND ...
-- 90% of rows are 'completed', 5% 'active', 5% 'cancelled'
```

**What's Wrong:**

A full index on `status` includes all values. A partial index only indexes
rows matching a WHERE clause — much smaller, faster to scan.

**Fix:**

```sql
-- ✅ Partial index: only index active orders (5% of table)
CREATE INDEX idx_orders_active ON orders (created_at)
    WHERE status = 'active';
```

**Detection:**

- Queries filtering on a low-cardinality column with skewed distribution
- Index larger than necessary for the filtered subset
- `pg_stat_user_indexes.idx_scan` = 0 for rarely-queried values

**Severity:** 🟡 Medium

---

## Pattern PG-4: Parallel Query Not Triggering

**SQL Signature:**

```sql
SELECT * FROM large_table WHERE condition;
-- Only 1 worker used, despite many CPU cores
```

**What's Wrong:**

PostgreSQL parallel query requires specific conditions: table size >
`min_parallel_table_scan_size`, enough parallel workers available,
`parallel_setup_cost` not prohibitively high. Many deployments have
parallel query configured but not triggering.

**Fix:**

```sql
-- Check settings:
SHOW max_parallel_workers;
SHOW max_parallel_workers_per_gather;
SHOW min_parallel_table_scan_size;
SHOW parallel_setup_cost;
SHOW parallel_tuple_cost;

-- Adjust for modern hardware:
ALTER SYSTEM SET max_parallel_workers = 8;            -- total across all sessions
ALTER SYSTEM SET max_parallel_workers_per_gather = 4; -- per query
ALTER SYSTEM SET min_parallel_table_scan_size = '4MB';
ALTER SYSTEM SET parallel_setup_cost = 100;
ALTER SYSTEM SET parallel_tuple_cost = 0.01;
SELECT pg_reload_conf();
```

**Detection:**

- `EXPLAIN` shows `Workers Planned: 1` or no parallel workers
- Large sequential scans on multi-core servers
- `max_parallel_workers` set to 0 or very low

**Severity:** 🟡 Medium

---

## Pattern PG-5: Function-Based Index Needed (Expression Index)

**SQL Signature:**

```sql
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
SELECT * FROM products WHERE (data->>'price')::numeric > 100;
```

**What's Wrong:**

Functions on indexed columns prevent index usage. PostgreSQL supports
indexes on expressions.

**Fix:**

```sql
-- ✅ Expression index
CREATE INDEX idx_users_email_lower ON users (LOWER(email));

-- ✅ Index on JSON field
CREATE INDEX idx_products_price ON products ((data->>'price')::numeric);
```

**Detection:**

- `LOWER()`, `UPPER()`, `EXTRACT()`, `::cast`, `->`/`->>` in WHERE clause
- `EXPLAIN` shows `Filter` or `Seq Scan` despite index on base column

**Severity:** 🟠 High

---

## Pattern PG-6: Bad `random_page_cost` for SSDs

**SQL Signature:**

```sql
-- Planner chooses Seq Scan even when index exists
SELECT * FROM medium_table WHERE indexed_col = ?;
-- EXPLAIN shows: Seq Scan (cost=...) despite idx_medium_table_indexed_col existing
```

**What's Wrong:**

Default `random_page_cost = 4.0` assumes HDDs. With SSDs, the planner
overestimates the cost of random I/O and chooses sequential scans when
index scans would be faster.

**Fix:**

```sql
-- ✅ For SSDs (including cloud block storage like gp3, io2)
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
SELECT pg_reload_conf();
```

**Detection:**

- `EXPLAIN` shows `Seq Scan` when an index exists on the filtered column
- `random_page_cost` is 4.0 (default)
- Storage is SSD/NVMe (check: `lsblk -d -o ROTA`)

**Severity:** 🔴 Critical (affects ALL queries)

---

## Pattern PG-7: Missing ANALYZE After Bulk Loads

**SQL Signature:**

```sql
-- After bulk INSERT/UPDATE/DELETE, queries get bad plans
SELECT * FROM table WHERE col = ?;
-- EXPLAIN shows Seq Scan, but index exists — stats are stale
```

**What's Wrong:**

After large data changes, statistics in `pg_statistic` are stale.
Autovacuum eventually runs ANALYZE, but the window between can cause
massively bad query plans.

**Fix:**

```sql
-- ✅ Run ANALYZE after bulk operations
ANALYZE large_table;

-- ✅ Or ANALYZE the whole database
ANALYZE;

-- ✅ For critical tables, lower autovacuum_analyze_scale_factor
ALTER TABLE large_table SET (autovacuum_analyze_scale_factor = 0.01);
```

**Detection:**

- Sudden planner regression after ETL/batch jobs
- `pg_stat_user_tables.last_analyze` is old relative to `n_mod_since_analyze`
- `n_mod_since_analyze` > `n_live_tup * 0.1`

**Severity:** 🟠 High (transient but severe)

---

## Pattern PG-8: Partitioning Not Used for Large Time-Series Tables

**SQL Signature:**

```sql
SELECT * FROM events WHERE created_at >= '2024-06-01' AND created_at < '2024-07-01';
-- Table has 50B rows across 5 years, no partitioning
```

**What's Wrong:**

Without partitioning, PostgreSQL scans all rows or uses a btree index that
may not fit in memory. Declarative partitioning (PG 10+) enables partition
pruning — only relevant partitions are scanned.

**Fix:**

```sql
-- ✅ Range partitioning by month
CREATE TABLE events (
    id BIGSERIAL,
    created_at TIMESTAMPTZ NOT NULL,
    data JSONB
) PARTITION BY RANGE (created_at);

CREATE TABLE events_2024_01 PARTITION OF events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
-- ... repeat for each month

-- ✅ Or use pg_partman for automatic partition management
```

**Detection:**

- Tables > 100M rows with timestamp columns
- `WHERE timestamp BETWEEN` filtering to recent ranges
- No partition info in `\d+ table`

**Severity:** 🟡 Medium (grows with data)

---

## Pattern PG-9: `work_mem` Too Low — HashAgg Instead of Sort+GroupAgg

**SQL Signature:**

```sql
SELECT category, COUNT(*) FROM large_table GROUP BY category;
-- EXPLAIN: HashAggregate (disk) — spilling to disk!
```

**What's Wrong:**

When `work_mem` is too low, hash aggregates spill to disk, dramatically
slowing GROUP BY queries. The planner may also choose suboptimal strategies
(Sort+GroupAgg over HashAgg) if it thinks hash tables won't fit.

**Fix:**

```sql
-- ✅ Increase work_mem (per operation, per query node)
ALTER SYSTEM SET work_mem = '16MB';  -- OLTP
-- Or per-session for reporting:
SET work_mem = '256MB';

-- ✅ Check for spills:
SELECT * FROM pg_stat_statements WHERE query LIKE '%HashAgg%';
```

**Detection:**

- `EXPLAIN ANALYZE` shows `Buckets: ... Batches: ... Memory Usage: ...`
  with Batches > 1 (spilling)
- `log_temp_files` shows large temp file writes
- `work_mem` is default (4MB)

**Severity:** 🟠 High (for aggregation queries)

---

## Pattern PG-10: Missing `VACUUM` After Heavy Updates/Deletes

**SQL Signature:**

```sql
-- After bulk DELETE or UPDATE:
SELECT COUNT(*) FROM table;
-- Takes long, even though table "should" be smaller now
-- EXPLAIN: Seq Scan with high heap fetches
```

**What's Wrong:**

PostgreSQL doesn't reclaim dead tuple space immediately — it marks rows as
dead and later VACUUM reclaims them. Heavy UPDATE/DELETE without VACUUM
causes table bloat, degrading all queries.

**Fix:**

```sql
-- ✅ Run VACUUM (concurrent, non-blocking)
VACUUM VERBOSE table_name;

-- ✅ For severe bloat, VACUUM FULL (exclusive lock!)
VACUUM FULL table_name;  -- CAREFUL: blocks all access

-- ✅ Monitor bloat:
SELECT schemaname, relname,
       n_dead_tup,
       n_live_tup,
       round(n_dead_tup * 100.0 / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables
WHERE n_dead_tup > 0
ORDER BY n_dead_tup DESC;
```

**Detection:**

- `pg_stat_user_tables.n_dead_tup` >> `n_live_tup`
- `n_mod_since_analyze` is high
- Sequential scans on tables that should be faster with indexes

**Severity:** 🔴 Critical (progressive degradation)

---

## PostgreSQL Index Checklist (additive to framework checklists)

1. ☐ `random_page_cost` set for SSD (1.1) vs HDD (4.0)
2. ☐ BRIN indexes on append-only timestamp columns on large tables
3. ☐ Partial indexes for queries filtering on low-selectivity columns
4. ☐ Expression indexes for `LOWER()`, `::cast`, JSON operators
5. ☐ `work_mem` appropriate for aggregate/sort queries
6. ☐ `ANALYZE` run after bulk data changes
7. ☐ Partitioning for time-series tables > 100M rows
8. ☐ `pg_stat_statements` installed and tracking
9. ☐ `auto_explain` configured for slow queries
10. ☐ Check for unused indexes: `SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0`
11. ☐ Check for duplicate indexes (same columns, different names)
12. ☐ `VACUUM` schedule appropriate for update frequency
