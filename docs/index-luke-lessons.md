# Use The Index, Luke! — Key Lessons

A distilled reference of the most impactful lessons from
[use-the-index-luke.com](https://use-the-index-luke.com/) by Markus Winand.
These principles apply across MySQL, PostgreSQL, Oracle, and SQL Server.

---

## 1. The Three Powers of an Index

An index does **three** things, not just one:

| Power | What | Example |
|-------|------|---------|
| **1st Power: Filter** | Find rows via `WHERE` | `WHERE status = 'active'` |
| **2nd Power: Join** | Link tables efficiently | `JOIN orders ON users.id = orders.user_id` |
| **3rd Power: Sort** | Avoid `ORDER BY` sort operations | `ORDER BY created_at DESC` |

A single composite index can serve all three powers **simultaneously** if
columns are ordered correctly:

```sql
-- This index serves all three powers:
CREATE INDEX idx_posts_user_status_date ON posts (user_id, status, created_at);

-- Query that benefits:
SELECT * FROM posts
WHERE user_id = 123          -- 1st power: filter
  AND status = 'published'   -- 1st power: filter
ORDER BY created_at DESC     -- 3rd power: sort
LIMIT 20;                    -- Top-N optimization
```

**Rule:** A database can pipeline `WHERE` + `JOIN` + `ORDER BY` through a
single index scan — no intermediate sort, no hash table. This is why
composite index design is the most valuable tuning skill.

---

## 2. Concatenated Index Column Order

The **single most important decision** when creating a multi-column index:
column order.

```
CREATE INDEX idx ON table (col_a, col_b, col_c)
```

An index with three columns supports searches on:

- `col_a` alone          ✓ (leading column)
- `col_a` + `col_b`      ✓ (leading columns)
- `col_a` + `col_b` + `col_c`  ✓ (all columns)
- `col_b` alone          ✗ (not leading)
- `col_c` alone          ✗ (not leading)
- `col_b` + `col_c`      ✗ (first column missing)

**Think of it like a telephone directory:** sorted by last name, then first
name. You can find by last name. You cannot find by first name alone.

### Column Order Strategy

1. **Equality conditions first** — columns checked with `=`
2. **Range conditions next** — columns checked with `>`, `<`, `BETWEEN`, `LIKE 'prefix%'`
3. **ORDER BY columns** — match the sort order
4. **Covering columns last** — columns only in SELECT (covering index)

```sql
-- WHERE status = ? AND created_at > ? ORDER BY priority
-- Equality:    status         (position 1)
-- Range:       created_at     (position 2)
-- ORDER BY:    priority       (position 3)
CREATE INDEX idx_order ON orders (status, created_at, priority);
```

### Myth: "Most Selective Column First"

> ❌ "Always put the most selective column first."

This is **wrong**. The correct principle is:

> ✓ "Choose the column order so the index can be used by as many queries as possible."

Selectivity only matters when you have **two independent range conditions**
and need to choose which index to create — not for column order within one
index.

---

## 3. Why "Slow Indexes" Happen

An index lookup has three steps:

```
1. Tree Traversal      → B-tree root → leaf (fast, O(log n))
2. Leaf Node Chain     → follow linked list for all matches (can be slow)
3. Table Access        → fetch actual row data from heap (can be slow)
```

An index is slow when:

- **Too many leaf nodes to scan** — the matched range is large (lots of
  matching entries in the leaf chain)
- **Too many table accesses** — each matched row requires a random I/O to
  the table heap

### Mitigations

| Problem | Solution |
|---------|----------|
| Many leaf node matches | Tighter `WHERE` clause, partial indexes |
| Many table accesses | **Covering index** (all columns in the index — avoids table access entirely) |
| Random I/O | Index-organized tables (InnoDB clustered index = PK), SSD storage |

```sql
-- Covering index: all needed columns IN the index
-- No table access needed — "Index Only Scan"
CREATE INDEX idx_covering ON posts (user_id, status, created_at, title);

SELECT user_id, title, created_at  -- All in the index ✓
FROM posts
WHERE user_id = 123 AND status = 'published'
ORDER BY created_at DESC;
```

---

## 4. Pipelined ORDER BY — Avoid the Sort

If the index already delivers rows in the required order, the database
**skips the sort operation entirely**.

```sql
-- Without pipelining (explicit sort needed):
CREATE INDEX idx_sale_date ON sales (sale_date);

SELECT * FROM sales
WHERE sale_date = '2024-01-15'
ORDER BY product_id;  -- Sort required! Index is ordered by sale_date, not product_id

-- With pipelining (sort eliminated):
CREATE INDEX idx_date_product ON sales (sale_date, product_id);

SELECT * FROM sales
WHERE sale_date = '2024-01-15'
ORDER BY product_id;  -- No sort! Index range is already in product_id order
```

**Rule:** If the `ORDER BY` columns match the index columns after the
equality conditions, the sort is pipeline-able.

### When Pipelining Breaks

- **Range condition on middle column** — breaks sort on subsequent columns
- **Mixed ASC/DESC** — needs matching index direction (MySQL 8.0+ supports
  descending indexes)
- **Different index used** — forced by optimizer for cost reasons

---

## 5. Keyset Pagination (Seek Method) vs OFFSET

The **offset method** (`LIMIT 20 OFFSET 50000`) scans all skipped rows:

```sql
-- ❌ OFFSET: scans rows 1-50020, discards 50000, returns 20
SELECT * FROM posts ORDER BY id DESC LIMIT 20 OFFSET 50000;

-- ✓ Keyset (seek): starts directly at the right position
SELECT * FROM posts
WHERE id < ?  -- Last seen ID from previous page
ORDER BY id DESC
LIMIT 20;
```

### Keyset Pagination Requirements

1. **Deterministic sort order** — if `ORDER BY created_at DESC` can have
   ties, add a unique column:

   ```sql
   ORDER BY created_at DESC, id DESC
   ```

2. **Row value comparison** (MySQL 8.0+, PostgreSQL 8.4+):

   ```sql
   -- "Comes after" the last seen row (descending order = <)
   WHERE (created_at, id) < (?, ?)
   ORDER BY created_at DESC, id DESC
   LIMIT 20
   ```

3. **Fallback for databases without row value support** (MySQL < 8.0
   using ORM patterns):

   ```sql
   WHERE (created_at < ?
          OR (created_at = ? AND id < ?))
   ORDER BY created_at DESC, id DESC
   LIMIT 20
   ```

### Performance Comparison

| Page | OFFSET Method | Seek Method |
|------|:---:|:---:|
| 1 | ~1ms | ~1ms |
| 10 | ~5ms | ~1ms |
| 100 | ~50ms | ~1ms |
| 1000 | ~500ms | ~1ms |

The seek method is **constant time** regardless of page depth.

---

## 6. N+1 Selects = Accidental Nested Loops

ORM "N+1 selects" are exactly the **nested loops join algorithm**, just
executed with individual network round-trips instead of a single SQL join.

```python
# ❌ N+1: 1 + N queries with network latency per loop iteration
employees = db.query("SELECT * FROM employees WHERE last_name LIKE 'Win%'")
for emp in employees:
    sales = db.query("SELECT * FROM sales WHERE employee_id = ?", emp.id)
    # Each query = network round-trip + query parse + index lookup

# ✓ Join: 1 query, database handles the nested loop internally
result = db.query("""
    SELECT e.*, s.*
    FROM employees e
    LEFT JOIN sales s ON e.id = s.employee_id
    WHERE e.last_name LIKE 'Win%'
""")
```

**The database does the exact same index lookups** in both cases, but the
join version avoids N network round-trips. Network latency dominates
response time far more than data volume (bandwidth).

| Method | Queries | Network Trips | Index Lookups |
|--------|:------:|:------------:|:-----------:|
| N+1 in app | N+1 | N+1 | N+1 |
| SQL JOIN | 1 | 1 | N+1 (DB does it) |

---

## 7. Index-Only Scans (Covering Indexes)

When **all requested columns exist in the index**, the database can skip
the table access entirely. This is the single most effective optimization
for read-heavy queries.

```sql
-- Without covering index: index scan + table access per row
CREATE INDEX idx_user ON posts (user_id);

-- With covering index: index-only scan, no table access
CREATE INDEX idx_user_covering ON posts (user_id, title, status, created_at);

SELECT user_id, title, status
FROM posts
WHERE user_id = 123        -- Uses index
ORDER BY created_at DESC;  -- Pipelined from index
```

**InnoDB note:** The primary key is always appended to secondary indexes
in InnoDB, so covering includes the PK automatically.

---

## 8. Function-Based Indexes

Never put a function on the indexed column in `WHERE` — it prevents index
usage. Instead, index the function:

```sql
-- ❌ Function on column = no index use
SELECT * FROM employees WHERE UPPER(last_name) = 'WINAND';

-- ✓ Function-based index (MySQL 8.0.13+)
CREATE INDEX idx_upper_name ON employees ((UPPER(last_name)));

-- Or (MySQL 5.7 / all versions):
-- Add a generated column + index
ALTER TABLE employees ADD COLUMN last_name_upper VARCHAR(255)
    GENERATED ALWAYS AS (UPPER(last_name)) STORED;
CREATE INDEX idx_upper_name ON employees (last_name_upper);
```

### Common offenders

| Instead of | Use |
|-----------|-----|
| `WHERE DATE(created_at) = '2024-01-15'` | `WHERE created_at >= '2024-01-15' AND created_at < '2024-01-16'` |
| `WHERE YEAR(created_at) = 2024` | `WHERE created_at >= '2024-01-01' AND created_at < '2025-01-01'` |
| `WHERE LOWER(email) = ?` | Function index on `(LOWER(email))` or use `utf8mb4_unicode_ci` collation |
| `WHERE CONCAT(first, ' ', last) = ?` | `WHERE first = ? AND last = ?` (use all parts separately) |

---

## 9. Partial Indexes (Filtered Indexes)

Index only a subset of rows — smaller, faster, less write overhead.

```sql
-- MySQL 8.0: No native partial index. Use functional index trick:
CREATE INDEX idx_active_orders ON orders (
    (CASE WHEN status = 'active' THEN created_at END)
);
-- Only non-NULL values are indexed (= active orders only)

-- PostgreSQL: Native partial index
CREATE INDEX idx_active_orders ON orders (created_at)
    WHERE status = 'active';
```

Best for: soft-deletes (`WHERE deleted_at IS NULL`), status columns with
skewed distribution, tenant isolation.

---

## 10. Indexing JOIN Columns

For nested loops joins (the most common type), index the **join columns on
the inner table** — the table accessed per-row of the driving table.

```sql
SELECT e.*, s.*
FROM employees e           -- Driving table (outer loop)
JOIN sales s               -- Inner table (probed per employee)
  ON e.id = s.employee_id  -- Index needed on s.employee_id!
WHERE UPPER(e.last_name) = 'WINAND';

-- Required indexes:
CREATE INDEX idx_emp_upper ON employees ((UPPER(last_name)));  -- For WHERE on driving table
CREATE INDEX idx_sales_emp ON sales (employee_id);             -- For JOIN on inner table
```

**Rule:**

- Index the driving table's `WHERE` columns
- Index the inner table's `JOIN` columns (FKs)

---

## 11. Indexing Doesn't Help INSERT

Indexes **never speed up INSERT** — they only add write overhead. Every
index on a table must be updated on INSERT, UPDATE (to indexed columns),
and DELETE.

**Rule of thumb:**

- Add indexes to make reads fast
- Remove unused indexes to make writes fast
- Every index is a trade-off

Find unused indexes:

```sql
-- MySQL: indexes never used
SELECT * FROM sys.schema_unused_indexes;

-- PostgreSQL:
SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;
```

---

## 12. Testing: Real Data Volume Matters

> "Sloppy indexing bites back at scale."

A query that runs in 5ms on a 10K-row dev database can take 50 seconds on
a 10M-row production table — with the same execution plan.

| Rows | Index Scan | Full Table Scan |
|-----:|:----------:|:---------------:|
| 1K | 0.1ms | 1ms |
| 100K | 0.2ms | 100ms |
| 10M | 0.3ms | 10,000ms |
| 100M | 0.5ms | 100,000ms |

The index scan scales **logarithmically** (B-tree depth). The full scan
scales **linearly**. This is why you must test with realistic data volumes.

---

## References

- [Use The Index, Luke!](https://use-the-index-luke.com/) — Full site by Markus Winand
- [SQL Performance Explained](https://sql-performance-explained.com/) — Book edition (Є9.95)
- [Modern SQL](https://modern-sql.com/) — SQL features across databases
- Appendix: [Execution Plans reference](https://use-the-index-luke.com/sql/explain-plan) per database
- Appendix: [Myth Directory](https://use-the-index-luke.com/sql/myth-directory) — debunking indexing myths
