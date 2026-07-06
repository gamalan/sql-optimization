# Lesson 2: The Where Clause — Indexing Search Conditions

**Source:** [use-the-index-luke.com/sql/where-clause](https://use-the-index-luke.com/sql/where-clause)

---

## Summary

The WHERE clause is where indexes earn their keep. This lesson covers
equality searches, concatenated (composite) keys, the effects of functions
and bind variables, range conditions, partial indexes, NULL handling, and
the critical role of column order.

---

## Lesson 2.1: Equality Searches & Primary Keys

### Primary Key Lookups

A primary key lookup uses `INDEX UNIQUE SCAN` — tree traversal only, no
leaf chain traversal. This is the fastest possible access path.

```sql
SELECT * FROM employees WHERE employee_id = 123;
-- MySQL EXPLAIN: type=const, key=PRIMARY
```

### Verifying Index Usage

Use `EXPLAIN` to confirm the index is being used. If `type: ALL` appears
on a query with a WHERE clause, no suitable index exists. Key MySQL
EXPLAIN fields:

- `type` — access method (`const`, `eq_ref`, `ref`, `range`, `index`, `ALL`)
- `key` — which index is used (NULL = none)
- `rows` — estimated rows examined
- `Extra` — additional operations (filesort, temporary, using index)

---

## Lesson 2.2: Concatenated (Composite) Indexes

### The Column Order Problem

A concatenated index on `(col_a, col_b, col_c)` is sorted first by
`col_a`, then by `col_b` within equal `col_a` values, then by `col_c`.

```sql
CREATE INDEX idx ON table (a, b, c);

-- ✓ Can use index:
WHERE a = ?                     -- leading column
WHERE a = ? AND b = ?           -- leading columns
WHERE a = ? AND b = ? AND c = ? -- all columns

-- ✗ Cannot use index (effectively):
WHERE b = ?                     -- a missing
WHERE c = ?                     -- a and b missing
WHERE b = ? AND c = ?           -- a missing
```

### The Telephone Directory Analogy

A telephone directory is sorted by (last_name, first_name). You can find
someone by last name alone. You cannot find someone by first name alone —
you'd have to scan the entire directory.

### Partial Index Usage

For `WHERE a = ? AND c = ?` (b is skipped):

- Index can be used for column `a` (access predicate)
- Column `c` is only a **filter predicate** — checked after retrieving rows
  matching `a`, not used to narrow the index scan

### Column Order Strategy

```
Position 1: Columns used with =     (equality — most selective access)
Position 2: Columns used with range (>, <, BETWEEN, LIKE 'prefix%')
Position 3: ORDER BY columns        (eliminate sort)
```

### Slow Indexes, Part II

Even with the right columns, the wrong column order can make an index
perform a full index scan instead of a range scan:

```sql
-- Index: (subsidiary_id, employee_id)
-- Query: WHERE employee_id = 123
-- Result: FULL INDEX SCAN — can't use the tree!

-- Index: (employee_id, subsidiary_id)
-- Query: WHERE employee_id = 123
-- Result: INDEX RANGE SCAN — uses the tree!
```

---

## Lesson 2.3: Functions on Indexed Columns

### The Fundamental Rule

**Never apply a function to the indexed column in the WHERE clause.** It
prevents index usage because the database indexes the raw column values,
not the function output.

```sql
-- ✗ Function on column → NO INDEX USE
WHERE UPPER(last_name) = 'SMITH'
WHERE DATE(created_at) = '2024-01-15'
WHERE YEAR(order_date) = 2024

-- ✓ No function → INDEX CAN BE USED
WHERE last_name = 'Smith'  -- (if case-sensitive collation)
WHERE created_at >= '2024-01-15' AND created_at < '2024-01-16'
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01'
```

### Solutions

| Approach | How | When |
|----------|-----|------|
| Rewrite to range | `WHERE col >= ? AND col < ?` | Date truncation, year/month extraction |
| Function-based index | `CREATE INDEX ON t ((UPPER(col)))` | Case-insensitive search (MySQL 8.0.13+) |
| Generated column | Add stored generated column + index | Older MySQL, complex expressions |
| Change collation | Use case-insensitive collation | Case-insensitive comparisons |

### Case-Insensitive Search

```sql
-- MySQL: function-based index (8.0.13+)
CREATE INDEX idx_upper_name ON employees ((UPPER(last_name)));

-- MySQL: generated column (all versions)
ALTER TABLE employees ADD COLUMN last_name_upper
    GENERATED ALWAYS AS (UPPER(last_name)) STORED;
CREATE INDEX idx_name ON employees (last_name_upper);

-- Or use case-insensitive collation at table/column level
-- (avoid function entirely)
```

### Over-Indexing

Adding too many indexes hurts write performance. Each INSERT/UPDATE/DELETE
must update ALL indexes. **Rule:** Create the minimum number of indexes
that cover your access patterns. Remove unused indexes regularly.

---

## Lesson 2.4: Bind Variables

Bind variables (parameterized queries) are essential for **both** security
(preventing SQL injection) and performance (enabling the database to reuse
execution plans).

```sql
-- ✗ Literal values: different SQL string = new plan each time
SELECT * FROM users WHERE id = 1;
SELECT * FROM users WHERE id = 2;

-- ✓ Bind variables: same SQL = plan reused
SELECT * FROM users WHERE id = ?;  -- ? = parameter
```

Without bind variables, the database must parse, optimize, and plan each
query separately — even for identical query structure. With bind variables,
the plan is cached and reused.

### The ORM Angle

Most ORMs use bind variables by default (they're a security feature). But
watch out for ORMs that generate literal values for IN clauses or dynamic
sort orders — those bypass plan caching.

---

## Lesson 2.5: Range Conditions

### Greater, Less, and BETWEEN

Range conditions use the index to find the starting point via tree
traversal, then follow the leaf node chain.

**Critical rule for composite indexes:** Only the columns BEFORE the first
range condition can be used as access predicates. Everything after is a
filter predicate only.

```sql
-- Index: (date_col, status, amount)
-- Query: WHERE date_col >= ? AND status = ? AND amount > ?
--         ^range              ^filter     ^filter
-- Only date_col is used as access predicate!
-- status and amount are checked after matching rows are fetched.

-- Better column order for this query:
-- Index: (status, date_col, amount)
--         ^eq     ^range    ^filter
-- status AND date_col are access predicates!
```

### LIKE Performance

- `LIKE 'prefix%'` — can use index (range scan from prefix)
- `LIKE '%middle%'` — cannot use index (leading wildcard → full scan)
- `LIKE '%suffix'` — cannot use index

For full-text search, use FULLTEXT indexes, not LIKE.

### Index Merge

Some databases can combine multiple indexes for a single table access
(via bitmap index scans, index merge). However, this is almost always
slower than a single composite index.

**Rule:** Don't create separate indexes hoping the database will merge
them. Create one composite index that covers all conditions.

---

## Lesson 2.6: Partial Indexes

Index only a subset of rows — smaller, faster, less write overhead.

```sql
-- PostgreSQL, SQL Server: native partial indexes
CREATE INDEX idx_active ON orders (created_at)
    WHERE status = 'active';

-- MySQL 8.0: emulate with functional index
CREATE INDEX idx_active ON orders (
    (CASE WHEN status = 'active' THEN created_at END)
);
-- Only non-NULL values are in the index (= active orders)
```

Best use cases: soft deletes, status filters, tenant isolation, sparse
data.

---

## Lesson 2.7: NULL in Indexes

NULL values are indexed (in most databases, including MySQL). However:

- `WHERE column IS NULL` — can use index
- `WHERE column IS NOT NULL` — can use index (MySQL 5.7+)
- Oracle treats empty strings as NULL (unique behavior)
- NOT NULL constraints help the optimizer make better decisions

---

## Key Takeaways

1. **Column order is the single most important index design decision** —
   equality first, then ranges, then ORDER BY
2. **Never wrap indexed columns in functions** — use range conditions or
   function-based indexes instead
3. **One composite index > multiple single-column indexes** — index merge
   is a fallback, not a strategy
4. **Bind variables are a performance feature** — they enable plan reuse,
   not just security
5. **Partial indexes reduce overhead** — index only the rows you query
