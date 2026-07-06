# Use The Index, Luke! — Agent Skill

An agent-agnostic skill that teaches and applies SQL indexing principles
from Markus Winand's classic [Use The Index, Luke!](https://use-the-index-luke.com/).

## What It Does

Teaches indexing concepts and diagnoses index-related performance issues
across MySQL, PostgreSQL, Oracle, SQL Server, and SQLite. When given a
slow query, the skill:

1. Maps the query to the **three index powers** (Filter, Join, Sort)
2. Diagnoses root causes via EXPLAIN plan analysis
3. Recommends the optimal index with column order rationale
4. Explains the trade-offs (write penalty, storage, covering index
   opportunity)

## Lessons

| # | Topic | File |
|---|-------|------|
| 1 | Anatomy of an Index | `lessons/01-anatomy.md` |
| 2 | The Where Clause | `lessons/02-where-clause.md` |
| 3 | Obfuscated Conditions | `lessons/03-obfuscation.md` |
| 4 | Testing & Scalability | `lessons/04-scalability.md` |
| 5 | The Join Operation | `lessons/05-joins.md` |
| 6 | Clustering Data | `lessons/06-clustering.md` |
| 7 | Sorting & Grouping | `lessons/07-sorting-grouping.md` |
| 8 | Partial Results (Pagination) | `lessons/08-pagination.md` |
| 9 | Insert, Delete, Update (DML) | `lessons/09-dml.md` |
| 10 | Myth Directory | `lessons/10-myths.md` |

## Usage

Point your agent at the skill and ask about slow queries, index design, or
EXPLAIN plans:

> "Why is this query slow even with an index? Here's the EXPLAIN output."

> "What's the right column order for a composite index on (a, b, c)?"

> "How do I paginate efficiently on a 10M-row table?"

The skill references the lesson files for authoritative content and
produces diagnoses with exact `CREATE INDEX` recommendations.

## Works With

- Cursor
- Claude Code
- Pi
- Codex
- Any agent that reads `SKILL.md` files

## Source

All content based on [Use The Index, Luke!](https://use-the-index-luke.com/)
by Markus Winand. The full site was fetched and organized into 10 lesson
modules covering ~45 pages of SQL indexing theory and practice.

## License

MIT — see [LICENSE](../../slow-query-analyzer/LICENSE)
