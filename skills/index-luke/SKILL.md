---
name: index-luke
description: SQL indexing expert based on Use The Index, Luke! — teaches and diagnoses index design, concatenated keys, pipelined ORDER BY, keyset pagination, covering indexes, join performance, and indexing anti-patterns. Use when asking about SQL indexing, slow queries, index design, composite indexes, or EXPLAIN plan analysis.
---

# Use The Index, Luke! — Expert Skill

## Purpose

Teach and apply SQL indexing principles from
[Use The Index, Luke!](https://use-the-index-luke.com/) by Markus Winand.
Diagnose index-related performance issues, design optimal composite indexes,
and explain indexing concepts to developers. This skill covers database-agnostic
indexing theory applicable to MySQL, PostgreSQL, Oracle, SQL Server, and SQLite.

## When to Use This Skill

Use this skill when the user asks about:

- **Index design** — "What index should I create?", "Why is my index not being used?"
- **Slow queries** — "Why is this query slow even with an index?"
- **Composite indexes** — "What's the right column order for a multi-column index?"
- **ORDER BY performance** — "Why does ORDER BY require a filesort?"
- **Pagination** — "How do I paginate efficiently on large tables?"
- **JOIN performance** — "Why are my JOINs slow?"
- **EXPLAIN output** — "What does this EXPLAIN plan mean?"
- **Index myths** — "Should I rebuild indexes?", "Should the most selective column go first?"
- **Covering indexes** — "How do I avoid table access?"

## Core Knowledge

This skill is backed by the full content of Use The Index, Luke!, organized
into 9 lesson modules plus a myth directory. Read the relevant lesson file
for detailed content before responding:

| # | Lesson | File | Key Concept |
|---|--------|------|-------------|
| 1 | Anatomy of an Index | `lessons/01-anatomy.md` | B-tree, leaf nodes, the three-step index lookup |
| 2 | The Where Clause | `lessons/02-where-clause.md` | Concatenated keys, functions, ranges, partial indexes |
| 3 | Obfuscated Conditions | `lessons/03-obfuscation.md` | Dates, numeric strings, smart logic, math anti-patterns |
| 4 | Testing & Scalability | `lessons/04-scalability.md` | Data volume effects, system load, response time vs throughput |
| 5 | The Join Operation | `lessons/05-joins.md` | Nested loops, hash joins, sort-merge, N+1 problem |
| 6 | Clustering Data | `lessons/06-clustering.md` | Index-only scans, covering indexes, clustered indexes |
| 7 | Sorting & Grouping | `lessons/07-sorting-grouping.md` | Pipelined ORDER BY, ASC/DESC, indexed GROUP BY |
| 8 | Partial Results | `lessons/08-pagination.md` | Top-N queries, keyset vs offset pagination, window functions |
| 9 | DML Performance | `lessons/09-dml.md` | INSERT/DELETE/UPDATE overhead from indexes |
| M | Myth Directory | `lessons/10-myths.md` | Index degeneration, most-selective-first, dynamic SQL |

## How to Answer Questions

### Step 1: Identify the Topic

Map the user's question to the relevant lesson(s) above. Read the lesson
file to get the authoritative content.

### Step 2: Explain with the Three-index Model

Every index-related answer should reference the three-step index lookup:

```
1. Tree Traversal    → B-tree root → leaf (fast, O(log n))
2. Leaf Node Chain   → follow linked list for matches (can be slow with many matches)
3. Table Access      → fetch row data from heap (can be slow with many rows)
```

### Step 3: Use the Three Powers Framework

Explain which of the three index powers the query needs:

| Power | SQL Clause | What It Does |
|-------|-----------|-------------|
| 1st: Filter | `WHERE` | Find specific rows via equality/range |
| 2nd: Join | `JOIN ... ON` | Link tables efficiently |
| 3rd: Sort | `ORDER BY`, `GROUP BY` | Avoid sort operations |

A single composite index can serve all three simultaneously with correct
column ordering.

### Step 4: Show the EXPLAIN Evidence

Always reference the relevant EXPLAIN operations. For MySQL:

- `type: ref` = index range scan (good)
- `type: ALL` = full table scan (bad on large tables)
- `Extra: Using filesort` = explicit sort needed (index might help)
- `Extra: Using temporary` = temp table needed (index might help)
- `Extra: Using index` = covering index (best — no table access)
- `Extra: Using where; Using index` = index-only scan with filter

### Step 5: Provide the Fix

Give the exact `CREATE INDEX` statement with column order rationale:

```sql
-- Column order: equality conditions → range conditions → ORDER BY columns
CREATE INDEX idx_name ON table_name (eq_col, range_col, order_col);
```

Explain WHY the order was chosen, referencing the concatenated index rules.

## Key Principles (Quick Reference)

### The Golden Rule of Column Order

```
Position 1: Equality conditions (=)
Position 2: Range conditions (>, <, BETWEEN, LIKE 'prefix%')
Position 3: ORDER BY columns (matching direction)
Position 4: SELECT columns (for covering indexes)
```

### When an Index Won't Be Used

1. **Leading column missing** — searching on non-leading columns of a
   composite index
2. **Function on indexed column** — `WHERE DATE(created_at) = ?`
3. **LIKE with leading wildcard** — `LIKE '%search'`
4. **Type mismatch** — comparing string column to number
5. **OR across different columns** — `WHERE col_a = ? OR col_b = ?`
6. **Low selectivity** — the optimizer chooses full scan for small result
   set percentage (~> 20% of table)
7. **NOT / != / <> conditions** — negative conditions can't use index
   range scans

### Covering Index Checklist

To make a query use an index-only scan:

- All columns in `SELECT` are in the index
- All columns in `WHERE` are in the index (leading positions)
- All columns in `ORDER BY` are in the index
- No large TEXT/BLOB columns in the index

### Keyset Pagination Pattern

```sql
-- ✓ Seek method (constant time)
SELECT * FROM posts
WHERE (created_at, id) < (?, ?)
ORDER BY created_at DESC, id DESC
LIMIT 20;

-- Fallback for MySQL < 8.0 without row values:
SELECT * FROM posts
WHERE created_at < ?
   OR (created_at = ? AND id < ?)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

### N+1 Detection

Watch for these SQL patterns:

```
SELECT * FROM posts WHERE user_id = ?     -- runs N times
SELECT * FROM comments WHERE post_id = ?  -- runs N*M times
```

The fix is always a JOIN or ORM eager loading, plus an index on the FK:

```sql
CREATE INDEX idx_posts_user_id ON posts (user_id);
CREATE INDEX idx_comments_post_id ON comments (post_id);
```

## Diagnosis Workflow

When given a slow query:

1. **Get the EXPLAIN plan** — `EXPLAIN FORMAT=JSON SELECT ...`
2. **Check the type** — `ALL` = full scan (problem), `ref`/`range` = index
   used (check if optimal)
3. **Check key** — Is it using the expected index? If `NULL`, no index found
4. **Check rows** — Is it examining many more rows than it returns?
5. **Check Extra** — `Using filesort`, `Using temporary` = index can help
6. **Check possible_keys** — Are there candidate indexes not being chosen?
7. **Check filtered** — What % of examined rows match? Low = bad index
   selectivity
8. **Recommend the index** — Apply the column ordering rules above
9. **Verify with EXPLAIN** — Show the improved plan (even if theoretical)

## Output Format

When analyzing a query, produce:

```
### Query Analysis: [short description]

**Current EXPLAIN:** [type, key, rows, Extra]
**Problem:** [root cause — missing index, wrong column order, function on column, etc.]
**Fix:**
```sql
CREATE INDEX idx_xxx ON table (col1, col2, ...);
```

**Column Order Rationale:** [why this order]
**Expected Improvement:** [type: ref, rows reduced by ~N%]
**Verification:**

```sql
EXPLAIN SELECT ... -- should show key: idx_xxx, no filesort/temporary
```

```

## Safety Rules

- Never recommend `ALTER TABLE` or `CREATE INDEX` without warning about:
  - Table locking during index creation (use `ALGORITHM=INPLACE, LOCK=NONE` for MySQL 5.6+)
  - Increased write overhead from the new index
  - Storage space requirements
- Never recommend dropping an index without verifying it's unused
  (`sys.schema_unused_indexes` for MySQL)
- Warn when an index recommendation might break a covering query that
  relies on the existing index
- Always check for redundant indexes before recommending new ones

## Sources

All content based on [Use The Index, Luke!](https://use-the-index-luke.com/)
by Markus Winand. Full lesson content in `lessons/*.md`.
