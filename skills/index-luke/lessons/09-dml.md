# Lesson 9: Insert, Delete, and Update — DML Performance

**Source:** [use-the-index-luke.com/sql/dml](https://use-the-index-luke.com/sql/dml)

---

## Summary

Indexes are pure overhead for writes. Every INSERT must add entries to
every index. Every DELETE must remove entries from every index. Every
UPDATE to an indexed column must modify every index. This lesson quantifies
the write penalty and teaches when to remove or avoid indexes.

---

## Lesson 9.1: INSERT — Indexes Only Add Cost

INSERTs cannot take any benefit from indexes — they are pure write
overhead. Every index on a table must be updated with the new row.

```
INSERT INTO table VALUES (...)

Cost = 1 table insert + (N_indexes × 1 index insert)
```

### The Penalty in Numbers

| Indexes | Relative INSERT Cost |
|--------:|:---:|
| 1 (PK only) | 1× |
| 3 | ~2.5× |
| 5 | ~4× |
| 10 | ~7× |
| 20 | ~12× |

Each additional index increases INSERT time. On tables with heavy write
traffic, every index must justify itself.

### InnoDB-Specific INSERT Behavior

- **Inserting in PK order:** Pages fill sequentially → minimal IO.
  Ideal: auto-increment PK.
- **Inserting randomly (UUID):** Pages split everywhere → heavy IO,
  fragmentation. **Avoid random PKs.**
- **Secondary indexes:** Random insert into secondary indexes = random
  B-tree page splits = slow.

### Bulk Inserts

```sql
-- ✓ Batch INSERT (one transaction):
INSERT INTO logs (msg, created_at) VALUES
    ('msg1', NOW()), ('msg2', NOW()), ... ('msg1000', NOW());

-- 1000× faster than 1000 individual INSERTs
```

---

## Lesson 9.2: DELETE — Indexes for WHERE, Penalty for Removal

DELETEs use indexes **for finding rows** (the WHERE clause benefit), but
must remove entries from **every index** after finding them.

```sql
DELETE FROM orders WHERE status = 'expired' AND created_at < '2024-01-01';

-- Uses index for finding (good!): (status, created_at)
-- Must update: PK index + (status, created_at) + (user_id) + ...
```

### Soft Deletes

Using a `deleted_at` column instead of DELETE:

```sql
-- Instead of DELETE (removes from all indexes):
DELETE FROM posts WHERE id = 123;

-- Soft delete (only touches one indexed column if indexed):
UPDATE posts SET deleted_at = NOW() WHERE id = 123;
-- Only updates indexes that contain deleted_at

-- Subsequent SELECTs filter:
SELECT * FROM posts WHERE deleted_at IS NULL;
```

**Index for soft deletes:** `(deleted_at, created_at)` — the leading
`deleted_at` column enables the index to support both the soft-delete
filter and common sort orders.

---

## Lesson 9.3: UPDATE — Only Affected Indexes Are Modified

UPDATEs modify indexes that contain any of the **changed columns**. Columns
not in the new values are not affected.

```sql
UPDATE posts SET title = 'New Title' WHERE id = 123;

-- Indexes updated: PK (id) — where clause benefit
--                   (title) if exists
-- Indexes NOT updated: (user_id), (created_at), etc.
```

### The "Updated Column Count" Penalty

An UPDATE changing 1 column touches fewer indexes than one changing 10
columns. BUT: even changing 0 visible columns (if an indexed column stays
the same), InnoDB still writes the entire row — it's an in-place UPDATE in
MySQL.

### Avoiding Index Updates

```sql
-- ✗ Useless UPDATE (writes all indexes):
UPDATE users SET updated_at = NOW(), last_login = last_login
WHERE id = 123;
-- last_login didn't change, but is still "updated" in the SQL

-- ✓ Only update what changed:
UPDATE users SET updated_at = NOW() WHERE id = 123;
```

---

## Key Takeaways

1. **Every index costs writes** — more indexes = slower INSERT, DELETE, and
   indexed-column UPDATE
2. **Remove unused indexes** — run `sys.schema_unused_indexes` regularly
3. **Batch INSERTS** — one multi-row INSERT beats N individual INSERTs
4. **Sequential PKs for InnoDB** — avoids page splits and fragmentation
   on INSERT
5. **Soft deletes can reduce index maintenance** — UPDATE one column
   instead of DELETE from all indexes
6. **Don't update columns that haven't changed** — the SQL counts as a
   write regardless
