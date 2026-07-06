# Lesson 8: Partial Results — Efficient Pagination

**Source:** [use-the-index-luke.com/sql/partial-results](https://use-the-index-luke.com/sql/partial-results)

---

## Summary

Fetching partial results (pagination) seems simple but has hidden
performance traps. This lesson covers top-N queries, the difference between
offset and keyset (seek) pagination, and window function approaches.

---

## Lesson 8.1: Top-N Queries

Fetching only the first N rows with `LIMIT` / `FETCH FIRST` lets the
database stop early:

```sql
-- MySQL
SELECT * FROM sales ORDER BY sale_date DESC LIMIT 10;

-- SQL Standard
SELECT * FROM sales ORDER BY sale_date DESC FETCH FIRST 10 ROWS ONLY;
```

### Pipelined Top-N

When an index matches the ORDER BY, the database reads exactly N rows from
the index (plus N table accesses) and stops — it never touches the rest.

```sql
CREATE INDEX idx_date ON sales (sale_date);

SELECT * FROM sales ORDER BY sale_date DESC LIMIT 10;
-- Reads: 10 index entries + 10 table rows → stops
-- Without index: reads ALL rows, sorts ALL, then discards all but 10
```

This is the most efficient query pattern possible — use it everywhere you
have "latest N" or "top N" requirements.

---

## Lesson 8.2: Fetch the Next Page — Offset vs Seek

### The Offset Method (Common, but Degenerates)

```sql
-- Page 1:  LIMIT 20 OFFSET 0    → scans 20 rows, returns 20
-- Page 10: LIMIT 20 OFFSET 180   → scans 200 rows, returns 20
-- Page 100:LIMIT 20 OFFSET 1980  → scans 2000 rows, returns 20
-- Page 100000:                    → scans 2,000,000 rows, returns 20
```

The offset method **scans all skipped rows**. Response time grows linearly
with page depth. This is why "page 500 takes forever" is a universal
complaint.

```
OFFSET performance:
Page    1: ~1ms
Page   10: ~5ms
Page  100: ~50ms
Page 1000: ~500ms
Page 10000: ~5s ← timeout!
```

### The Seek Method (Keyset Pagination)

Uses the **values** of the last row from the previous page as a filter,
so the database truly skips over unseen rows:

```sql
-- Page 1:
SELECT * FROM posts
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Page 2 (last row of page 1: created_at='2024-06-15', id=5000):
SELECT * FROM posts
WHERE (created_at, id) < ('2024-06-15', 5000)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

**Performance is CONSTANT regardless of page depth:**

- Page 1: ~1ms
- Page 1000: ~1ms
- Page 1,000,000: ~1ms

### Requirements for Seek Pagination

1. **Deterministic sort order** — if `ORDER BY created_at DESC` can have
   ties, add a unique column: `ORDER BY created_at DESC, id DESC`
2. **Row value comparison** — `WHERE (col_a, col_b) < (?, ?)` (MySQL
   8.0+, PostgreSQL 8.4+, DB2)
3. **Fallback for MySQL < 8.0:**

   ```sql
   WHERE created_at < ?
      OR (created_at = ? AND id < ?)
   ORDER BY created_at DESC, id DESC
   LIMIT 20
   ```

### Trade-offs

| Feature | Offset | Seek |
|---------|:---:|:---:|
| Jump to arbitrary page | ✓ | ✗ |
| Constant performance | ✗ | ✓ |
| Stable across inserts | ✗ | ✓ |
| Simple to implement | ✓ | ✗ |
| Forward + backward | ✓ | ✗ (complex) |
| Infinite scroll friendly | ✗ | ✓ |

For infinite scroll UIs (the dominant pattern), seek pagination is the
clear winner.

---

## Lesson 8.3: Window Functions for Pagination

```sql
-- Pagination with ROW_NUMBER()
SELECT *
FROM (
    SELECT *, ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
    FROM posts
) t
WHERE rn BETWEEN 21 AND 40;
```

Window functions are useful for pagination when you need:

- Page numbers (row numbering with offsets)
- Multiple sort criteria with complex ranking
- Partition-based pagination (top-N per category)

However, they cannot avoid scanning the rows before the window — for deep
pagination, seek method is still superior.

---

## Key Takeaways

1. **Top-N queries with matching indexes are the fastest possible** — the
   database reads exactly N rows and stops
2. **OFFSET pagination degrades linearly** — scanning all skipped rows is
   wasted I/O
3. **Keyset (seek) pagination is constant-time** — the index `WHERE`
   clause lets the database jump to the right position
4. **Deterministic ORDER BY is mandatory** for seek pagination — add a
   unique column to the sort
5. **Choose seek for infinite scroll, offset for page-numbered UIs** — but
   know the trade-off
