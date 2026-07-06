# Lesson 1: Anatomy of an SQL Index

**Source:** [use-the-index-luke.com/sql/anatomy](https://use-the-index-luke.com/sql/anatomy)

---

## Summary

An SQL index is a B-tree structure with two key components: the **tree**
(for fast traversal) and the **leaf node chain** (a doubly-linked list for
range scans). Understanding this structure is essential to diagnosing why
indexes can sometimes be slow.

A slow index lookup is NOT caused by a "degenerated" or "unbalanced" tree
(a persistent myth). It's caused by the two steps that come AFTER the tree
traversal: following the leaf node chain, and accessing the table.

---

## Lesson: The Leaf Nodes

The leaf nodes of a B-tree index form a **doubly-linked list**. Each leaf
node contains:

- The indexed column value(s)
- A row identifier (ROWID / primary key) pointing to the actual table row

The linked-list structure is why an index can support both **equality
lookups** (via tree traversal) and **range scans** (follow the chain).
Without the chain, the database would need to re-traverse the tree for
each adjacent value.

Key insight: the leaf node chain means that an `INDEX RANGE SCAN` on a
large range must traverse many leaf nodes — each potentially in a
different disk block. This is the #1 reason range scans can be slow.

---

## Lesson: The B-Tree

The B-tree (Balanced Tree) structure:

- **Root node** — entry point, points to branch nodes
- **Branch nodes** — intermediate levels, narrow the search
- **Leaf nodes** — contain actual index entries + row pointers

Properties:

- All leaf nodes are at the **same depth** (balanced)
- Each node contains multiple entries (high fan-out)
- Tree depth is typically 3-5 levels even for billions of rows

This structure enables **logarithmic lookup time**: finding one row in a
billion-row table requires only ~3-4 node traversals.

### Balance Myth

The tree is **always balanced** by construction — nodes split when full.
An index never becomes "unbalanced" like a binary tree could. Index rebuilds
do not improve tree balance or traversal speed.

---

## Lesson: Slow Indexes, Part I — Two Ingredients

An index lookup has exactly three steps:

```
1. TREE TRAVERSAL     → Root → leaf node (always fast, O(log n))
2. LEAF NODE CHAIN    → Follow linked list for all matching entries
3. TABLE ACCESS       → Fetch row from table for each match
```

### Ingredient 1: Leaf Node Chain

When a range condition matches many entries, the database must traverse
many leaf nodes along the chain. Each might be on a different disk page.

**Example:** `WHERE subsidiary_id = 20` with 10,000 matching rows spread
across 1,000 leaf nodes = 1,000 random disk reads to follow the chain.

### Ingredient 2: Table Access

For each matched index entry, the database must fetch the actual row from
the table. These rows are typically scattered across the table (poor
clustering factor), resulting in one random I/O per row.

**Example:** 10,000 matching index entries × 1 random table access each =
10,000 random disk reads.

### The Operations (Oracle terminology, but concept is universal)

| Operation | Steps | When Used |
|-----------|-------|-----------|
| `INDEX UNIQUE SCAN` | Tree traversal only | Unique constraint guarantees ≤1 match |
| `INDEX RANGE SCAN` | Tree + leaf chain | Multiple possible matches |
| `TABLE ACCESS BY INDEX ROWID` | Fetch row from table | Per matched row (unless covering index) |

### MySQL equivalents

- `type: eq_ref` — unique index lookup (INDEX UNIQUE SCAN)
- `type: ref` — non-unique index lookup (INDEX RANGE SCAN)
- `type: range` — range condition on index
- `Extra: Using index` — covering index (no table access needed)

---

## Key Takeaways

1. **Indexes are NOT just B-trees** — the leaf node chain is equally important for range scans
2. **A slow index is NOT "broken"** — it's just matching too many entries (large range) or doing too many table accesses
3. **Tree traversal is always fast** — the slowdown is always in the leaf chain or table access
4. **Rebuilding indexes doesn't fix slow indexes** — it's a myth; the correct fix is a better index design or covering index
5. **Covering indexes eliminate table access** — include all needed columns to avoid the random I/O penalty

---

## Practical Application

When you see a query that uses an index but is still slow:

1. Check how many rows are being matched (the leaf chain scan volume)
2. Check if each row requires a table access (look for `Using index` in
   MySQL EXPLAIN)
3. If not `Using index`, consider a **covering index** that includes the
   SELECT columns
4. If the range is too broad, tighten the WHERE clause or use a partial
   index
