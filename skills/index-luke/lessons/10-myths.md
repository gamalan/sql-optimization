# Lesson 10: Myth Directory

**Source:** [use-the-index-luke.com/sql/myth-directory](https://use-the-index-luke.com/sql/myth-directory)

---

## Summary

Persistent myths about SQL indexing lead to wasted time, unnecessary index
rebuilds, and suboptimal designs. This lesson debunks the most common ones.

---

## Myth 1: Indexes Degenerate Over Time and Need Rebuilding

> ❌ "Indexes become fragmented and unbalanced — rebuild them regularly."

**False.** B-trees are always balanced by construction. When a node is full,
it splits — the tree grows in depth uniformly. Page splits create empty
space (fragmentation) but this affects storage efficiency, not lookup
speed. The tree's log(n) lookup property is preserved. Rebuilding only
_temporarily_ reduces fragmentation and is disruptive (locks, I/O, buffer
pool eviction).

**Rebuild only when:** deleting >50% of rows, changing page size or fill
factor, or after non-INPLACE ALTER TABLE.

---

## Myth 2: The Most Selective Column Should Be First

> ❌ "Always put the most distinct column first in a composite index."

**False.** The correct principle: **choose column order so the index can be
used by as many queries as possible.** A low-selectivity column first can
enable pipelined ORDER BY or support more query patterns. Selectivity only
matters for choosing between two independent single-column indexes — not
for composite column order. This myth persists in SQL Server because
histograms are only kept for the first column; the real advice is "put
unevenly distributed columns first."

---

## Myth 3: Dynamic SQL Is Slow

> ❌ "Building queries dynamically in code is slower than static SQL."

**False.** Dynamic SQL is often **faster** because each variant uses a
specific, optimal index. The alternative — "smart logic" with
`WHERE (col = ? OR ? IS NULL)` — forces full table scans. Dynamic SQL
**with bind variables** caches execution plans just like static SQL. The
myth conflates two separate issues: plan caching (solved by bind variables)
and SQL injection (solved by parameterization).

---

## Myth 4: `SELECT *` Is Always Bad

> ❌ "Never use SELECT *."

**Nuanced.** The wildcard itself is syntax sugar. The real issues: (1)
unnecessary columns waste network/memory, (2) prevents covering indexes
(database must access table for all columns even if index has the needed
ones), (3) breaks when schema columns change. Use explicit column lists
when you want covering indexes or need fewer columns — but don't cargo-cult
the `*` ban without understanding why.

---

## Myth 5: Oracle Cannot Index NULL

> ❌ "Oracle can't index NULL values."

**False.** Modern Oracle indexes NULL. Single-column indexes include NULL;
composite indexes exclude only rows where ALL columns are NULL. `WHERE
column IS NULL` can use the index. This myth persists from historical
documentation ambiguity.

---

## Myth 6: More Indexes Always Help

> ❌ "If a query is slow, add an index. More can't hurt."

**False.** Every index costs: slower INSERT/DELETE/UPDATE, more disk
space, more buffer pool memory (reducing cache for data), and more
optimizer plan evaluation overhead. Add indexes only when they measurably
improve reads AND the write penalty is acceptable. Remove unused indexes
via `sys.schema_unused_indexes` regularly.

---

## Key Takeaways

1. **Don't rebuild indexes** — B-trees self-balance; rebuilds are
   temporary and disruptive
2. **Column order is about query coverage, not selectivity** — the
   "most selective first" myth is one of the most harmful
3. **Dynamic SQL with bind variables is fast and index-friendly** —
   it's the "smart logic" workaround that kills performance
4. **Explicit column lists enable covering indexes** — that's the
   real reason to avoid `SELECT *`, not the wildcard itself
5. **Every index has a write cost** — index purposefully, remove
   unused ones, and measure the trade-off
