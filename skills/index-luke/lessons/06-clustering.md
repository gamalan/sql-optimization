# Lesson 6: Clustering Data

**Source:** [use-the-index-luke.com/sql/clustering](https://use-the-index-luke.com/sql/clustering)

---

## Summary

Clustering is about reducing I/O by organizing data to minimize disk
accesses. This lesson covers covering indexes (index-only scans), the
index-organized table (clustered index), and using index filter predicates
strategically.

---

## Lesson 6.1: Index Filter Predicates for LIKE

Sometimes you intentionally want an index to scan more entries than
necessary — because the alternative (table access) is more expensive.

### Tuning LIKE with Filter Predicates

```sql
-- Index: (first_name, last_name, date_of_birth)

SELECT * FROM employees
WHERE first_name = 'JOHN'
  AND last_name LIKE 'S%'
ORDER BY date_of_birth;

-- Execution:
-- 1. Access: first_name = 'JOHN' → tree traversal
-- 2. Filter: last_name LIKE 'S%' → scans all Johns, filters by S*
-- 3. Sort: date_of_birth → already in index order, pipelined!
```

The `LIKE` on `last_name` causes the database to scan all Johns (not just
S* Johns), but the pipelined ORDER BY avoids a costly sort. The trade-off
(extra index scan rows vs. eliminating sort) often favors the index scan.

---

## Lesson 6.2: Index-Only Scan (Covering Index)

### The Ultimate Optimization

When **all columns referenced by the query** exist in the index, the
database skips the table access entirely — the most effective single
optimization.

```sql
-- Without covering index:
CREATE INDEX idx_user_status ON orders (user_id, status);

SELECT user_id, status, COUNT(*)
FROM orders
WHERE user_id = 123
GROUP BY status;
-- Execution: INDEX RANGE SCAN → TABLE ACCESS BY INDEX ROWID per row

-- With covering index:
CREATE INDEX idx_covering ON orders (user_id, status, created_at);

SELECT user_id, status, created_at, COUNT(*)
FROM orders
WHERE user_id = 123
GROUP BY status, created_at;
-- Execution: INDEX ONLY SCAN — no table access at all!
-- MySQL EXPLAIN: "Using index"
```

### How to Design a Covering Index

1. Start with WHERE columns (equality → range)
2. Add GROUP BY / ORDER BY columns
3. Add SELECT columns (except those already in steps 1-2)

```sql
-- Query:
SELECT id, title, created_at
FROM posts
WHERE user_id = ? AND status = 'published'
ORDER BY created_at DESC
LIMIT 20;

-- Covering index:
CREATE INDEX idx_covering ON posts (user_id, status, created_at, id, title);
--                                   ^^^^^^^^ ^^^^^^  ^^^^^^^^^^  ^^  ^^^^^
--                                   WHERE=   WHERE=  ORDER BY    SEL  SEL
```

### Trade-offs

- **Pro:** Eliminates random table I/O (often 10-100× speedup)
- **Con:** Larger index (more disk, more memory for buffer pool, more
  write overhead)
- **Rule:** Cover frequently-run, read-heavy queries. Don't cover every
  query.

### InnoDB Note

InnoDB's secondary indexes automatically include the primary key at the
leaf level. So `PRIMARY KEY (id)` means a secondary index on `(user_id)`
is effectively `(user_id, id)` — the PK is always "free" in covering
indexes.

---

## Lesson 6.3: Index-Organized Tables (Clustered Indexes)

### InnoDB = Index-Organized Table

In InnoDB (MySQL's default engine), the **primary key IS the table**.
Table data is stored in the B-tree of the primary key — there is no
separate "heap" table.

```
MyISAM:  Index → ROWID → Heap table (separate)
InnoDB:  Primary Key B-tree = the table itself
         Secondary Index → Primary Key value → Primary Key B-tree
```

### Implications

1. **Every secondary index lookup requires TWO B-tree traversals:**
   secondary index → PK value → PK B-tree (the table)
2. **Short PKs are critical:** the PK value is stored in every secondary
   index leaf node. `BIGINT` PK = 8 bytes × millions of secondary index
   entries.
3. **Insert order matters:** inserting rows in PK order avoids page splits;
   inserting randomly fragments the PK B-tree (the table itself!)
4. **Covering indexes avoid the PK lookup** — this is why `Using index`
   is such a big win in InnoDB

### Choosing a Good Primary Key

- **Sequential** (avoid random inserts → fragmentation)
- **Small** (saves space in secondary indexes)
- **Stable** (never updated — UPDATE on PK = DELETE + INSERT)
- **Monotonically increasing** (UUID v4 is terrible; UUID v7 / ULID is OK)

---

## Key Takeaways

1. **Covering indexes are the single best optimization** — eliminate all
   table I/O for a query
2. **InnoDB IS the PK** — the table is stored in PK order; secondary
   indexes point to the PK
3. **Every secondary index lookup costs 2 B-tree traversals in InnoDB**
4. **Short, sequential PKs matter** — they reduce secondary index size and
   prevent fragmentation
5. **Filter predicates can be strategic** — sometimes scanning extra index
   entries to pipeline ORDER BY beats a sort
