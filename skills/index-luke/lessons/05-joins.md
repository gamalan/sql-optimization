# Lesson 5: The Join Operation

**Source:** [use-the-index-luke.com/sql/join](https://use-the-index-luke.com/sql/join)

---

## Summary

Joins aren't slow — bad indexing for joins is. This lesson covers the
three join algorithms (nested loops, hash join, sort-merge), how to index
for each, and why the ORM N+1 problem is just nested loops with network
round-trips.

---

## Lesson 5.1: Nested Loops Join

### How It Works

```
For each row in the driving (outer) table:
    Look up matching rows in the inner table using the join condition
```

Like nested for-loops in code. The database:

1. Scans the driving table (via index or full scan)
2. For each row, probes the inner table using the join columns

### Indexing for Nested Loops

```sql
SELECT e.*, s.*
FROM employees e
JOIN sales s ON e.employee_id = s.employee_id
WHERE e.last_name = 'Smith';

-- Required indexes:
CREATE INDEX idx_emp_name ON employees (last_name);      -- Driving table WHERE
CREATE INDEX idx_sales_emp ON sales (employee_id);       -- Inner table JOIN column
```

**Rule:** Index the **join columns on the inner table** and the **filter
columns on the driving table**.

### The N+1 Problem is Nested Loops with Network Latency

```python
# ORM N+1 (1 + N queries):
employees = db.query("SELECT * FROM employees WHERE last_name = 'Smith'")
for emp in employees:
    sales = db.query("SELECT * FROM sales WHERE employee_id = ?", emp.id)
# Total: N+1 queries, N+1 network round-trips

# SQL JOIN (1 query):
result = db.query("""
    SELECT * FROM employees e
    JOIN sales s ON e.employee_id = s.employee_id
    WHERE e.last_name = 'Smith'
""")
# Total: 1 query, 1 network round-trip
# Same index lookups happen inside the database!
```

### ORM Eager Fetching

Every major ORM supports join fetching at query time:

```ruby
# Rails: includes (chooses preload or eager_load automatically)
Employee.includes(:sales).where(last_name: 'Smith')

# Django: select_related (JOIN) or prefetch_related (separate query)
Employee.objects.select_related('sales').filter(last_name='Smith')

# Laravel: with (eager load)
Employee::with('sales')->where('last_name', 'Smith')->get();

# Prisma: include
prisma.employee.findMany({
  where: { lastName: 'Smith' },
  include: { sales: true }
})
```

---

## Lesson 5.2: Hash Join

### How It Works

1. Build a **hash table** from the smaller (build) table
2. Scan the larger (probe) table, looking up matches in the hash table

MySQL 8.0.18+ supports hash joins for equality conditions.

### Indexing for Hash Joins

Hash joins do NOT use indexes on the join columns — they use a hash table
in memory instead. However:

- Indexes on the **probe table's WHERE clause** are still useful
- Indexes on the **build table's WHERE clause** help reduce the hash table size

### When Hash Joins Beat Nested Loops

- Large result sets from both tables (> ~10K rows)
- No useful index on the inner table's join column
- Equality join conditions (hash joins can't do range joins)

### Partial Objects & Hash Joins

Loading only some columns from the joined table? Hash joins can fetch just
the needed columns:

```sql
-- Hash join can fetch employee name directly without accessing employee table
SELECT s.*, e.first_name, e.last_name
FROM sales s
JOIN employees e ON s.employee_id = e.employee_id;
```

If the hash table includes `first_name` and `last_name`, the employee
table access is skipped — analogous to a covering index for nested loops.

---

## Lesson 5.3: Sort-Merge Join

### How It Works

1. Sort both tables by the join columns
2. Merge the two sorted sets like a zipper

Used when both tables are large and the join is on range conditions
(which hash joins can't handle).

### Indexing for Sort-Merge

- Index on the **join columns of both tables** — eliminates the sort step
- If an index already delivers rows in the right order, the sort is
  pipelined

---

## Join Algorithm Selection

| Condition | Preferred Algorithm |
|-----------|-------------------|
| Small driving set, indexed inner table | Nested Loops |
| Large sets, equality join | Hash Join |
| Large sets, range join | Sort-Merge |
| Any, but indexed both sides | Nested Loops or Sort-Merge |

MySQL optimizes between nested loops and hash joins automatically (8.0.18+).
You control it by creating (or not creating) the right indexes.

---

## Key Takeaways

1. **N+1 in ORMs = nested loops join with network round-trips** — the
   database does the same work either way; the JOIN just avoids latency
2. **Index the inner table's FK columns** — the most common missing
   index for joins
3. **Hash joins don't need join-column indexes** — but still need WHERE
   clause indexes
4. **Choose the join algorithm by indexing** — provide indexes for nested
   loops; withhold them for hash joins
5. **Partial objects (selecting specific columns) helps hash joins** —
   fewer columns in the hash table = more rows fit in memory
