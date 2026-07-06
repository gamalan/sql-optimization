# SQLite-Specific Slow Query Patterns

These patterns are **additive** to the framework-specific patterns
(`laravel.md`, `django.md`, etc.). SQLite has unique configuration options
and anti-patterns that don't exist in client-server databases.

## Database-Specific Anti-Patterns

---

## Pattern SL-1: DELETE Journal Mode Instead of WAL

**SQL Signature:**

```sql
PRAGMA journal_mode;  -- returns: delete
```

**What's Wrong:**

`DELETE` journal mode (the historical default) uses a rollback journal.
Readers block writers, writers block readers. Any write-heavy application
or concurrent access pattern will experience `SQLITE_BUSY` errors or slow
performance.

**Fix:**

```sql
-- ✅ WAL mode: concurrent reads + writes, faster, crash-safe
PRAGMA journal_mode = WAL;

-- Persistent: the PRAGMA survives after the connection closes in WAL mode
```

**Detection:**

- `PRAGMA journal_mode` returns `delete`, `truncate`, or `persist`
- Applications report `database is locked` errors
- Write-heavy ORM workloads (web apps, background jobs)

**Severity:** 🔴 Critical (for any concurrent or write-heavy workload)

---

## Pattern SL-2: FULL Synchronous When NORMAL Would Suffice (WAL Mode)

**SQL Signature:**

```sql
PRAGMA synchronous;  -- returns: 2 (FULL) in WAL mode
```

**What's Wrong:**

In WAL mode, `synchronous = FULL` adds an extra fsync per transaction. WAL
mode already provides crash safety; `synchronous = NORMAL` is safe in WAL
because the WAL file itself is synced before the checkpoint.

**Fix:**

```sql
-- ✅ NORMAL is safe in WAL mode (WAL itself is always synced)
PRAGMA synchronous = NORMAL;
```

**Trade-off:** `NORMAL` may corrupt the database on power loss if the OS
crashes at the exact wrong moment during checkpoint. `FULL` prevents this
at the cost of ~2x slower writes. For most web apps, `NORMAL` in WAL is
the right choice.

**Detection:**

- `PRAGMA journal_mode` = `wal` AND `PRAGMA synchronous` = `FULL` (2)
- Write throughput lower than expected

**Severity:** 🟡 Medium

---

## Pattern SL-3: Small `cache_size` for the Workload

**SQL Signature:**

```sql
PRAGMA cache_size;  -- returns: -2000 (2MB default!)
```

**What's Wrong:**

The default `cache_size` is 2MB, which is insufficient for any real
workload. SQLite relies on its page cache (and OS page cache) for
performance. A small cache means frequent disk reads.

**Fix:**

```sql
-- ✅ For web apps: 5-10% of RAM as KB
PRAGMA cache_size = -51200;  -- 50 MB (negative = KB)

-- ✅ For analytics: up to 40% of RAM
PRAGMA cache_size = -512000; -- 500 MB

-- ✅ For embedded/mobile: 2-16 MB
PRAGMA cache_size = -8192;   -- 8 MB
```

**Detection:**

- `PRAGMA cache_size` ≤ 2000 pages (~2MB default)
- Application reads far exceed writes in `PRAGMA stats` (if available)
- Database on slow storage (SD card, network mount, HDD)

**Severity:** 🟠 High (for any non-trivial database)

---

## Pattern SL-4: `mmap_size = 0` (Memory-Mapped I/O Disabled)

**SQL Signature:**

```sql
PRAGMA mmap_size;  -- returns: 0
```

**What's Wrong:**

When `mmap_size = 0`, every read requires a `read()` system call. Enabling
memory-mapped I/O maps the database file (or a portion) into the process
address space, eliminating read syscalls for cached pages.

**Fix:**

```sql
-- ✅ Map the entire database (or up to your cache size)
PRAGMA mmap_size = 268435456;  -- 256 MB

-- ✅ On 64-bit systems, you can map the entire DB
--    (SQLite uses only pages that are actually accessed)
PRAGMA mmap_size = 1073741824; -- 1 GB
```

**Caveats:**

- Not available on all platforms (OpenBSD, some embedded systems)
- 64-bit systems only for large mappings
- On Linux, check `vm.max_map_count` if mapping very large databases

**Detection:**

- `PRAGMA mmap_size` = 0
- Read-heavy workload on a database larger than cache
- Linux/macOS 64-bit (where mmap is well-supported)

**Severity:** 🟡 Medium (read-heavy workloads benefit most)

---

## Pattern SL-5: `busy_timeout = 0` (No Lock Wait)

**SQL Signature:**

```sql
PRAGMA busy_timeout;  -- returns: 0
```

**What's Wrong:**

With `busy_timeout = 0`, any lock conflict immediately returns
`SQLITE_BUSY`. Even in WAL mode, multiple writers or a reader during
checkpoint can cause lock conflicts.

**Fix:**

```sql
-- ✅ Wait up to 5 seconds before returning SQLITE_BUSY
PRAGMA busy_timeout = 5000;
```

**Detection:**

- Application logs show `database is locked` or `SQLITE_BUSY` errors
- `PRAGMA busy_timeout` = 0
- Concurrent write access pattern

**Severity:** 🟠 High (for concurrent applications)

---

## Pattern SL-6: Table Scan on Large Table Without Covering Index

**SQL Signature:**

```sql
-- Given: SELECT a, b, c FROM t WHERE a = ? ORDER BY b
-- With:   CREATE INDEX idx_a ON t(a);  (only a is indexed)
-- EXPLAIN QUERY PLAN: SCAN TABLE t
```

**What's Wrong:**

SQLite's query planner chooses a full table scan if the index doesn't
cover enough columns. A covering index includes all columns referenced in
the query (SELECT, WHERE, ORDER BY, GROUP BY).

**Fix:**

```sql
-- ✅ Covering index: a = equality, b = ORDER BY, c = SELECT
CREATE INDEX idx_t_abc ON t(a, b, c);

-- EXPLAIN QUERY PLAN will show: SEARCH TABLE t USING COVERING INDEX idx_t_abc
```

**Detection:**

- `EXPLAIN QUERY PLAN` shows `SCAN TABLE` instead of `SEARCH`
- Index on some but not all query columns
- SQLite version supports covering indexes (3.7+)

**Severity:** 🟠 High (for large tables > 10K rows)

---

## Pattern SL-7: Not Using `WITHOUT ROWID` for Compound Primary Keys

**SQL Signature:**

```sql
-- Current schema:
CREATE TABLE user_roles (
    user_id INTEGER NOT NULL,
    role_id INTEGER NOT NULL,
    assigned_at TEXT,
    PRIMARY KEY (user_id, role_id)
);
-- Each row stores: rowid (8 bytes) + user_id + role_id + assigned_at
```

**What's Wrong:**

By default, SQLite tables are rowid tables — they store an implicit 64-bit
rowid. For tables with compound primary keys (or non-integer PKs), this
duplicates the key in both the btree and the row. `WITHOUT ROWID` tables
use a clustered index on the PRIMARY KEY, eliminating the rowid overhead.

**Fix:**

```sql
-- ✅ WITHOUT ROWID: primary key IS the row storage (~50% space savings for compound PKs)
CREATE TABLE user_roles (
    user_id INTEGER NOT NULL,
    role_id INTEGER NOT NULL,
    assigned_at TEXT,
    PRIMARY KEY (user_id, role_id)
) WITHOUT ROWID;
```

**Detection:**

- Tables with compound primary keys or TEXT primary keys
- Tables without `WITHOUT ROWID`
- Large join tables (many-to-many relationships)

**Severity:** 🟡 Medium (space + I/O savings on large tables)

---

## Pattern SL-8: Missing `ANALYZE` for Query Planner Statistics

**SQL Signature:**

```sql
-- Database has > 1000 rows but queries use suboptimal indexes
-- sqlite_stat1 is empty or missing
SELECT count(*) FROM sqlite_stat1;  -- returns: 0
```

**What's Wrong:**

Without `ANALYZE`, SQLite uses heuristics (equal distribution assumption)
to choose indexes. Running `ANALYZE` populates `sqlite_stat1` with actual
row counts and value distribution, enabling the query planner to make
better index choices.

**Fix:**

```sql
-- ✅ Run ANALYZE after significant data changes
ANALYZE;

-- ✅ Create sqlite_stat1 if it doesn't exist (if STAT4 is enabled, sqlite_stat4 too)
-- These are auto-created by ANALYZE

-- ✅ For very large tables, analyze specific tables
ANALYZE large_table;
```

**Detection:**

- `SELECT count(*) FROM sqlite_stat1` = 0
- `EXPLAIN QUERY PLAN` chooses suboptimal index despite better one existing
- Database recently bulk-loaded

**Severity:** 🟠 High

---

## Pattern SL-9: `temp_store = FILE` Instead of MEMORY

**SQL Signature:**

```sql
PRAGMA temp_store;  -- returns: 1 (FILE)
```

**What's Wrong:**

`temp_store = FILE` writes temporary tables and intermediate sort results
to disk. For queries with ORDER BY, GROUP BY, DISTINCT, or large
intermediate results, this adds significant disk I/O.

**Fix:**

```sql
-- ✅ Keep temp tables in memory (faster, but uses more RAM)
PRAGMA temp_store = MEMORY;  -- 2

-- ⚠️  Only safe if:
-- 1. temp data fits in available RAM, or
-- 2. SQLite's cache spill mechanism can handle overflow
```

**Detection:**

- Queries with ORDER BY, GROUP BY, or DISTINCT on large datasets
- `PRAGMA temp_store` = FILE (1) or DEFAULT (0)
- System has sufficient RAM for temp results

**Severity:** 🟡 Medium

---

## Pattern SL-10: Lack of `INTEGER PRIMARY KEY` for Auto-Increment

**SQL Signature:**

```sql
-- Suboptimal:
CREATE TABLE items (
    id TEXT PRIMARY KEY,    -- TEXT PK, NOT an alias for rowid
    name TEXT
);

-- Each row: rowid (hidden, 8 bytes) + id (TEXT, variable) + name (TEXT)
```

**What's Wrong:**

In SQLite, `INTEGER PRIMARY KEY` is a special alias for the internal
`rowid`. Using it means no extra column for the rowid, and lookups by PK
are direct btree seeks. Any other PK type (TEXT, BLOB, REAL, composite, or
`INT PRIMARY KEY` — note `INT` ≠ `INTEGER`) adds an extra unique index.

**Fix:**

```sql
-- ✅ Fastest: INTEGER PRIMARY KEY aliases rowid (no extra storage)
CREATE TABLE items (
    id INTEGER PRIMARY KEY,   -- auto-increments if NULL inserted
    name TEXT
);

-- ✅ If you MUST use TEXT PK (UUID), use WITHOUT ROWID
CREATE TABLE items (
    id TEXT PRIMARY KEY,
    name TEXT
) WITHOUT ROWID;
```

**Detection:**

- Tables with TEXT or composite primary keys but NOT `WITHOUT ROWID`
- Tables with `INT PRIMARY KEY` (note: `INT` ≠ `INTEGER` in SQLite!)
- Many single-column PK lookups

**Severity:** 🟡 Medium

---

## SQLite PRAGMA Optimization Checklist

When analyzing a SQLite database query, check:

1. ☐ `PRAGMA journal_mode` = WAL (not DELETE/TRUNCATE/PERSIST)
2. ☐ `PRAGMA synchronous` = NORMAL (safe in WAL mode)
3. ☐ `PRAGMA cache_size` appropriate for workload (not default 2MB)
4. ☐ `PRAGMA mmap_size` > 0 for read-heavy on 64-bit (Linux/macOS)
5. ☐ `PRAGMA busy_timeout` ≥ 5000ms for concurrent access
6. ☐ `PRAGMA temp_store` = MEMORY (if RAM allows)
7. ☐ `PRAGMA foreign_keys` = ON (for FK enforcement)
8. ☐ Covering indexes for common SELECT queries
9. ☐ `WITHOUT ROWID` for tables with compound or TEXT PKs
10. ☐ `ANALYZE` run after schema changes or bulk loads
11. ☐ `INTEGER PRIMARY KEY` used for auto-increment IDs
12. ☐ `PRAGMA integrity_check` passes (no corruption)
13. ☐ `PRAGMA freelist_count` < 10% of pages (low fragmentation)
14. ☐ Compile with `ENABLE_STAT4` for better ANALYZE histograms
