# Lesson 7: Sorting & Grouping

**Source:** [use-the-index-luke.com/sql/sorting-grouping](https://use-the-index-luke.com/sql/sorting-grouping)

---

## Summary

An index can eliminate explicit sort operations for both ORDER BY and
GROUP BY — the **third power** of indexing. This lesson covers pipelined
ORDER BY, the interaction with WHERE, ASC/DESC modifiers, NULL handling,
and pipelined GROUP BY.

---

## Lesson 7.1: Indexed ORDER BY (Pipelined Sort)

### The Core Principle

If the index already delivers rows in the required order, the database
**skips the sort operation entirely**. This is called a "pipelined ORDER BY."

```sql
-- Without pipelining: EXPLAIN shows "Using filesort"
CREATE INDEX idx_date ON sales (sale_date);

SELECT * FROM sales
WHERE sale_date = '2024-01-15'
ORDER BY product_id;
-- Sort needed! Index is in sale_date order, not product_id order.

-- With pipelining: EXPLAIN shows no filesort
CREATE INDEX idx_date_product ON sales (sale_date, product_id);

SELECT * FROM sales
WHERE sale_date = '2024-01-15'
ORDER BY product_id;
-- No sort! All matching rows share sale_date, so they're in product_id order.
```

### The Rule

An ORDER BY can be pipelined through an index when:

- All `WHERE` equality conditions match the leading index columns, AND
- The `ORDER BY` columns match the next index columns in order

### WHERE Clause Interactions

```sql
-- Index: (a, b, c, d)

-- ✓ Pipelined: eq on a,b → remaining index order is (c,d)
WHERE a = ? AND b = ? ORDER BY c, d

-- ✓ Pipelined: eq on a → remaining index order is (b,c,d)
WHERE a = ? ORDER BY b, c

-- ✗ NOT pipelined: range on a → b order not guaranteed for different a values
WHERE a > ? ORDER BY b

-- ✗ NOT pipelined: ORDER BY skips b
WHERE a = ? ORDER BY c
-- Reason: rows with same 'a' but different 'b' are not in 'c' order
```

### Detecting Pipeline Failure

If EXPLAIN shows `Using filesort` but you expected pipelining:

1. Run the query with all index columns in the ORDER BY
2. If filesort disappears → your original ORDER BY doesn't match index
   order
3. If filesort persists → the optimizer chose a different plan for cost
   reasons

---

## Lesson 7.2: ASC/DESC and NULLS FIRST/LAST

### Mixed ASC/DESC

MySQL 8.0+ supports **descending indexes**:

```sql
-- Index for ORDER BY created_at DESC, priority ASC
CREATE INDEX idx ON tasks (created_at DESC, priority ASC);

SELECT * FROM tasks
ORDER BY created_at DESC, priority ASC;  -- Pipelined!
```

Without descending indexes (MySQL 5.7), mixing ASC/DESC always requires a
sort — the index can only be scanned in the order it was created.

### NULL Handling

- MySQL: `NULL` values are treated as lower than any non-NULL value
  (ASC: NULLs first; DESC: NULLs last)
- PostgreSQL: supports `NULLS FIRST` / `NULLS LAST` in index definition
- Oracle: `NULL` values are the highest (ASC: NULLs last)

If your query uses `ORDER BY ... NULLS LAST` but the index stores NULLs
first, pipelining breaks. Match your index to the query's NULL ordering.

---

## Lesson 7.3: Indexed GROUP BY

### Pipelined GROUP BY

The same principle applies to GROUP BY: if rows are in group order, the
database can pipeline the grouping:

```sql
-- Index: (product_id, sale_date)
SELECT product_id, MAX(amount)
FROM sales
GROUP BY product_id;
-- Pipelined! Rows with same product_id are contiguous in the index.
```

### The Loose Index Scan

MySQL uses a "loose index scan" for `MIN()` and `MAX()` when the grouped
column is the leading index column. It jumps directly to the first/last
row of each group without scanning the entire index.

```sql
-- Index: (product_id, sale_date)
SELECT product_id, MIN(sale_date), MAX(sale_date)
FROM sales
GROUP BY product_id;
-- Loose index scan: jumps to each product_id group boundary
```

### GROUP BY vs DISTINCT

`GROUP BY` can often use indexes; `DISTINCT` often requires a sort or
temporary table. When possible, prefer GROUP BY with an indexed column
over DISTINCT.

---

## Key Takeaways

1. **Pipelined ORDER BY is the 3rd power of indexing** — one index can
   filter AND sort simultaneously
2. **Equality before the ORDER BY columns is critical** — a range condition
   before ORDER BY columns can break pipelining
3. **Match ASC/DESC to the index** — use descending indexes (MySQL 8.0+)
   for mixed sort directions
4. **Loose index scan for MIN/MAX** — the leading GROUP BY column in the
   index enables constant-time per-group lookups
5. **Prefer GROUP BY over DISTINCT** — GROUP BY is more index-friendly
