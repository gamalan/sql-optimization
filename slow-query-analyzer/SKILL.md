---
name: slow-query-analyzer
description: Analyze slow queries across MySQL, PostgreSQL, and SQLite — map them to framework ORM code patterns (Laravel, Django, Rails, Prisma, SQLAlchemy, GORM, Entity Framework). Diagnose N+1, missing indexes, missing eager loading, and framework-specific anti-patterns. Provide actionable, framework-idiomatic fixes.
---

# Slow Query Framework Analyzer (Multi-Database)

## Purpose

Extract slow queries from MySQL (Performance Schema), PostgreSQL
(pg_stat_statements), or SQLite (schema analysis) — fingerprint them, and
map each query pattern to the **application code that produces it** —
identifying the framework, ORM, and exact anti-pattern at fault.

This skill works with the companion script `analyze-slow-queries.sh` to
pull query data, then uses framework-specific and database-specific pattern
knowledge to diagnose the root cause and recommend an idiomatic fix.

**Frameworks covered:**

| Framework | ORM | Language |
|-----------|-----|----------|
| Laravel | Eloquent / Query Builder | PHP |
| Django | Django ORM | Python |
| Rails | ActiveRecord | Ruby |
| Prisma | Prisma Client | TypeScript / Node.js |
| SQLAlchemy | SQLAlchemy ORM | Python |
| GORM | GORM | Go |
| Entity Framework | EF Core | C# |

**Database-specific additive patterns:**

| Database | Pattern File | Key Focus |
|----------|-------------|-----------|
| PostgreSQL | `patterns/postgresql.md` | CTEs, BRIN indexes, partial indexes, parallel workers, partitioning, tablespaces |
| SQLite | `patterns/sqlite.md` | WAL tuning, PRAGMA optimization, WITHOUT ROWID, covering indexes, temp tables |

## Entry Modes

The skill supports three ways to get query data per database:

### Mode A: Live Database Access

Agent has database credentials and can query the database directly. Run the
companion script or query manually:

| Database | Source | Companion Script Command |
|----------|--------|--------------------------|
| MySQL | `performance_schema.events_statements_summary_by_digest` | `--dbtype mysql -h HOST -u USER -d DB` |
| PostgreSQL | `pg_stat_statements` | `--dbtype postgresql -h HOST -U USER -d DB` |
| SQLite | Schema analysis + EXPLAIN QUERY PLAN | `--dbtype sqlite -f /path/to/database.db` |

### Mode B: Offline Log File

User provides a slow query log file:

```bash
# MySQL slow query log
./analyze-slow-queries.sh --from-slow-log /path/to/mysql-slow.log --dbtype mysql

# PostgreSQL log (CSV or stderr format)
./analyze-slow-queries.sh --from-slow-log /path/to/postgresql.log --dbtype postgresql

# SQLite: no log needed — always works with the .db file directly
./analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db
```

### Mode C: Pasted Query List (Manual)

User pastes a list of slow queries from any source (application logs, APM,
monitoring tools). The agent fingerprints them, identifies patterns, and
maps to framework anti-patterns regardless of database.

### Auto-Detection

The script auto-detects the database type by probing connectivity. Omit
`--dbtype` to let it try MySQL → PostgreSQL, or specify `-f` for SQLite.

```bash
# Auto-detect (tries MySQL first, then PostgreSQL)
./analyze-slow-queries.sh -h db-host -u user -d mydb -o report.json

# Explicit
./analyze-slow-queries.sh --dbtype postgresql -h db-host -U postgres -d mydb -o report.json
./analyze-slow-queries.sh --dbtype sqlite -f app.db -o report.json
```

## Preconditions

Before running, the agent needs:

1. **Query source** — one of: live MySQL access, a slow query log file, or
   pasted query list (see Entry Modes above).
2. **Application repository path** — so the agent can map fingerprints to
   actual code files. If provided, the agent searches the repo for ORM
   calls that match the fingerprint.
3. **Framework identified** — the agent auto-detects the framework from the
   repository (see Phase 2), or the user specifies it. If unknown, the
   agent analyzes query shapes to guess, then confirms with the user.

### When the Agent Cannot Access the Database

This is the default for many teams — production databases are locked down.
The agent adapts:

1. **Ask the user to provide the slow query log.** Instructions to export:

   ```bash
   # On the MySQL server:
   # If slow query log file:
   cat /var/log/mysql/mysql-slow.log | head -5000 > slow-sample.log

   # If using Performance Schema (preferred):
   mysql -e "SELECT DIGEST_TEXT, COUNT_STAR,
                    ROUND(AVG_TIMER_WAIT/1000000000,2) AS avg_ms,
                    ROUND(SUM_TIMER_WAIT/1000000000,2) AS total_ms
             FROM performance_schema.events_statements_summary_by_digest
             WHERE DIGEST_TEXT IS NOT NULL
             ORDER BY SUM_TIMER_WAIT DESC LIMIT 50;" > top-queries.txt
   ```

2. **Or ask for a screenshot/copy from monitoring tools** — New Relic,
   Datadog APM, Percona PMM, pt-query-digest output, or Rails logs.

3. **For EXPLAIN data:** If the user can run queries on a replica or
   staging, provide the SQL and ask them to paste the EXPLAIN output.

4. **Proceed with limited data.** Even without live access, the agent can:
   - Fingerprint queries from the log
   - Map SQL shapes to framework ORM patterns
   - Detect N+1, missing indexes, bad pagination from query structure
   - Recommend fixes using the pattern database
   - Mark findings that need EXPLAIN verification as "unverified"

5. **Flag gaps explicitly.** The report marks each finding's confidence
   level:
   - 🟢 **Verified** — EXPLAIN output confirms the diagnosis
   - 🟡 **Likely** — Pattern matching strongly suggests this (needs EXPLAIN confirmation)
   - 🟠 **Possible** — Query shape matches, but needs more investigation

## Phase 0: Ingest Query Data (Offline Mode)

When the agent cannot access the production database, the user provides
query data. The agent handles these formats:

### 0a. Slow Query Log File

```bash
# User runs on their DB server:
cat /var/log/mysql/mysql-slow.log | head -2000 > /tmp/slow-sample.log

# Agent parses it locally:
./analyze-slow-queries.sh --from-slow-log /tmp/slow-sample.log -o report.json
```

The agent extracts from slow log format:

- `# Time: YYYY-MM-DDTHH:MM:SS` → timestamp
- `# User@Host: ...` → connection info
- `# Query_time: N.NNN  Lock_time: N.NNN  Rows_sent: N  Rows_examined: N` → metrics
- The SQL statement that follows → query fingerprint

### 0b. Pasted Queries (Any Format)

When a user pastes queries directly, the agent fingerprints them:

```
User: "These are from our pt-query-digest report:

# Rank 1: 245.2s total, 12.3ms avg, 19921 calls
# SELECT * FROM `posts` WHERE `posts`.`user_id` = 5\G

# Rank 2: 180.1s total, 45.2ms avg, 3984 calls
# SELECT COUNT(*) FROM `comments` WHERE `comments`.`post_id` = 123\G"
```

Or from application logs:

```
User: "From our Rails logs, these are slow:

  Post Load (245.3ms)  SELECT `posts`.* FROM `posts` WHERE `posts`.`user_id` = 1
  Comment Count (180.1ms) SELECT COUNT(*) FROM `comments` WHERE `comments`.`post_id` = 42
  -- And this pattern repeats for every request..."
```

The agent extracts:

1. SQL statements (normalize literals to `?` for fingerprinting)
2. Timing info if available (milliseconds)
3. Call counts if available
4. Groups identical-shaped queries to detect N+1

### 0c. Fingerprinting Rules (Manual Mode)

When fingerprinting pasted queries, the agent normalizes:

| Original | Fingerprint |
|----------|-------------|
| `SELECT * FROM users WHERE id = 42` | `SELECT * FROM users WHERE id = ?` |
| `SELECT * FROM users WHERE id = 999` | `SELECT * FROM users WHERE id = ?` |
| `INSERT INTO logs (msg, ts) VALUES ('hello', '2024-01-01')` | `INSERT INTO logs (msg, ts) VALUES (?, ?)` |
| `UPDATE posts SET title = 'Hi' WHERE id = 5` | `UPDATE posts SET title = ? WHERE id = ?` |
| `SELECT * FROM posts WHERE user_id IN (1,2,3)` | `SELECT * FROM posts WHERE user_id IN (?)` |

The agent groups queries by fingerprint and reports:

- How many distinct fingerprints were found
- Which fingerprints have the most instances (likely N+1)
- Which fingerprints appear with the longest durations

## Phase 1: Extract Slow Queries (Live Mode)

When live database access is available, run the companion script:

```bash
# MySQL
./slow-query-analyzer/analyze-slow-queries.sh \
    --dbtype mysql -h <host> -u <user> -p <password> -d <db> \
    -o slow-queries-report.json

# PostgreSQL
./slow-query-analyzer/analyze-slow-queries.sh \
    --dbtype postgresql -h <host> -U <user> -d <db> \
    -o slow-queries-report.json

# SQLite
./slow-query-analyzer/analyze-slow-queries.sh \
    --dbtype sqlite -f /path/to/database.db \
    -o slow-queries-report.json
```

The script produces a JSON report with:

- Top queries by total time, avg time, rows examined, and execution count
- Query fingerprints (normalized SQL with `?` placeholders)
- Database and table information
- Index usage analysis (MySQL: `SUM_NO_INDEX_USED`, PostgreSQL: `shared_blks_read`)
- EXPLAIN output for each top fingerprint

If the script cannot connect, the agent falls back to querying directly:

```sql
-- MySQL (Performance Schema)
SELECT DIGEST_TEXT, COUNT_STAR,
       ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS avg_ms,
       ROUND(SUM_TIMER_WAIT / 1000000000, 2) AS total_ms,
       ROUND(SUM_ROWS_EXAMINED / COUNT_STAR, 0) AS avg_rows,
       SUM_NO_INDEX_USED, SUM_NO_GOOD_INDEX_USED
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT IS NOT NULL AND SCHEMA_NAME = '<database>'
ORDER BY SUM_TIMER_WAIT DESC LIMIT 30;

-- PostgreSQL (pg_stat_statements)
SELECT LEFT(query, 200) AS fingerprint, calls,
       ROUND(mean_exec_time::numeric, 2) AS avg_ms,
       ROUND(total_exec_time::numeric / 1000, 4) AS total_sec,
       shared_blks_read AS disk_reads,
       shared_blks_hit AS cache_hits
FROM pg_stat_statements
JOIN pg_database d ON d.oid = dbid
WHERE d.datname = '<database>' AND query NOT LIKE '%pg_stat%'
ORDER BY total_exec_time DESC LIMIT 30;

-- SQLite (no built-in stats — run EXPLAIN QUERY PLAN)
EXPLAIN QUERY PLAN SELECT * FROM table WHERE condition;
```

## Phase 2: Detect Framework

Determine the framework from the repository. Check for these signals:

### Laravel

```
Found: composer.json with "laravel/framework"
Signals:
  - app/Models/*.php (Eloquent models)
  - config/database.php
  - routes/web.php, routes/api.php
  - database/migrations/*.php
```

### Django

```
Found: requirements.txt or pyproject.toml with "django"
Signals:
  - manage.py
  - settings.py with DATABASES
  - models.py in app directories
  - urls.py
  - migrations/ directories
```

### Rails

```
Found: Gemfile with "rails" or "activerecord"
Signals:
  - app/models/*.rb
  - db/migrate/*.rb
  - config/database.yml
  - config/routes.rb
```

### Prisma

```
Found: package.json with "prisma" or "@prisma/client"
Signals:
  - prisma/schema.prisma
  - node_modules/.prisma/
```

### SQLAlchemy

```
Found: requirements.txt / pyproject.toml with "sqlalchemy" (but NOT "django")
Signals:
  - models.py / models/*.py with declarative_base() or Base
  - database.py with create_engine()
  - alembic/ directory
```

### GORM

```
Found: go.mod with "gorm.io/gorm"
Signals:
  - models/*.go with gorm.Model
  - database/*.go with gorm.Open()
```

### Entity Framework

```
Found: *.csproj with "Microsoft.EntityFrameworkCore"
Signals:
  - DbContext classes
  - Migrations/ folder
```

If no repository is available, the agent asks the user which framework
they use and continues with the relevant pattern database.

## Phase 3: Map Queries to Framework Patterns

For each top slow query fingerprint, cross-reference against the
framework-specific patterns in `patterns/<framework>.md`. The pattern
files contain:

- **Signature** — SQL shape that identifies the pattern
- **ORM cause** — the exact ORM code that generates this SQL
- **Anti-pattern** — what's wrong (N+1, missing index, full scan, etc.)
- **Fix** — idiomatic framework code to fix it
- **Severity** — Critical / High / Medium / Low

### Pattern Recognition Heuristics

When the fingerprint doesn't exactly match a known pattern, the agent uses
these heuristics:

1. **Table name → Model mapping:**
   `users` → `User` model (most frameworks use PascalCase singular for
   models, snake_case plural for tables)

2. **SELECT columns → ORM select style:**
   - `SELECT *` → `Model::all()` or `Model.objects.all()` (no column
     selection)
   - `SELECT id, name` → `Model::select('id', 'name')` or
     `.values('id', 'name')`

3. **WHERE clauses → ORM filter style:**
   - `WHERE column = ?` → `where('column', value)` or
     `filter(column=value)`
   - `WHERE column IN (?,?,...)` → `whereIn('column', array)` or
     `filter(column__in=list)`
   - `WHERE column LIKE ?` → `where('column', 'like', '%value%')`

4. **JOINs → Relationship loading:**
   - `INNER JOIN` → `.join()` or `.select_related()`
   - `LEFT JOIN` → `.leftJoin()` or `.prefetch_related()`
   - Multiple identical JOINs to same table → **N+1 evidence** (failed
     eager loading)

5. **Aggregates → ORM aggregate style:**
   - `COUNT(*)` → `.count()` or `.aggregate(Count(...))`
   - `SUM(column)` → `.sum('column')` or `.aggregate(Sum(...))`
   - `GROUP BY` → `.groupBy()` or `.annotate().values()`

6. **ORDER BY + LIMIT → Pagination:**
   - `LIMIT ? OFFSET ?` → offset pagination (slow on large tables)
   - `ORDER BY id` → default ordering

### N+1 Query Detection (Critical)

N+1 is the most damaging anti-pattern. The agent detects it by:

1. **Multiple similar fingerprints** sharing a table name pattern:

   ```
   SELECT * FROM "posts" WHERE "user_id" = ?
   SELECT * FROM "comments" WHERE "post_id" = ?
   ```

   Appearing together with high frequency → likely N+1.

2. **High execution count + low avg_rows** — many tiny queries.

3. **Fingerprints appearing in bursts** (check FIRST_SEEN / LAST_SEEN
   clustering in Performance Schema).

4. **Framework signature detection** — see `patterns/<framework>.md` for
   the exact N+1 signatures per ORM.

### Missing Index Detection

For queries where `SUM_NO_INDEX_USED > 0` or `SUM_NO_GOOD_INDEX_USED > 0`:

1. Run `EXPLAIN` on the fingerprint
2. Check `type: ALL` (full table scan)
3. Check `Extra: Using filesort` or `Extra: Using temporary`
4. Recommend the optimal composite index based on:
   - Columns in WHERE equality conditions
   - Columns in WHERE range conditions
   - Columns in ORDER BY
   - Columns in GROUP BY

### Large Scans Detection

When `avg_rows_examined >> avg_rows_sent`:

1. Missing LIMIT clause
2. Missing WHERE selectivity
3. Bad index chosen (check `EXPLAIN` → `key` column)
4. Cursor pagination needed instead of OFFSET

## Phase 4: Analyze Context in the Codebase

For each problematic fingerprint, if the application repository is
available, the agent locates the code:

1. **Map table name to model:** Search for model definition files
2. **Map fingerprint to ORM calls:** Use the pattern database to guess the
   ORM method, then search the repo:

   ```bash
   # Example for Laravel: find where Post model queries user relation
   rg "Post::" app/ --type php -l
   rg "->where\(.*user_id" app/ --type php
   ```

3. **Find the controller/route:** Trace from model → controller → route
4. **Read the actual code:** Open and inspect the relevant file to confirm
   the diagnosis
5. **Verify the diagnosis:** Confirm that the ORM anti-pattern is exactly
   what's in the code

## Phase 5: Produce the Report

The final output must include, for each top query:

```markdown
### Query #N: [Short Description]

**Fingerprint:**
```sql
SELECT * FROM "posts" WHERE "posts"."user_id" = ?
```

**Metrics:**

| Metric | Value |
|--------|-------|
| Executions | 12,345/hr |
| Avg time | 245ms |
| Total time | 840s |
| Rows examined / sent | 500,000 / 1 |
| No index used | ✓ (full scan) |

**Framework:** Laravel (Eloquent)
**Anti-pattern:** N+1 — lazy-loading `posts` relation on `User` model

**Likely Code Location:**

- `app/Models/User.php` — `posts()` relation defined
- `app/Http/Controllers/UserController.php:42` — `User::all()` without eager loading

**Root Cause:**

```php
// ❌ Current code (N+1)
$users = User::all();
foreach ($users as $user) {
    echo $user->posts->count();  // Triggers 1 query PER user
}

// ✅ Fixed code
$users = User::with('posts')->get();
foreach ($users as $user) {
    echo $user->posts->count();  // 2 queries total
}
```

**Fix:**

- [ ] Add `->with('posts')` in `UserController.php:42`
- [ ] Add composite index: `CREATE INDEX idx_posts_user_id ON posts(user_id, created_at)`
- [ ] Estimated improvement: ~98% reduction in query count

**Severity:** 🔴 Critical

```

## Output Format

The final report contains:

1. **Executive Summary** — top 3-5 problems ranked by total time
2. **Query-by-Query Analysis** — detailed per-query breakdown as above
3. **Aggregate Statistics** — indexed vs unindexed %, query time by framework pattern, etc.
4. **Recommended Fixes (Prioritized)** — ordered by impact × ease of fix
5. **Index Recommendations** — DDL statements with rationale
6. **Code Changes** — file paths with before/after snippets

End with:

> **No changes have been applied.** All fixes require manual review and approval.

## Safety Rules

The agent MUST NOT:

- Run `ALTER TABLE` or `CREATE INDEX` directly
- Modify application code without explicit approval
- Run `EXPLAIN ANALYZE` on production during peak hours (it executes the query)
- Change MySQL configuration based on query findings alone
- Recommend denormalization or schema changes without discussing trade-offs

The agent SHOULD:

- Use `EXPLAIN` (not `EXPLAIN ANALYZE`) on production unless approved
- Recommend framework-idiomatic fixes, not raw SQL rewrites
- Prioritize fixes by (total_time_saved) × (ease_of_implementation)
- Flag when a fix might break existing behavior
- Verify that recommended indexes don't duplicate existing ones

## Framework Pattern References

For detailed ORM pattern signatures, fixes, and code examples, read the
framework-specific pattern files:

- `patterns/laravel.md` — Eloquent & Query Builder
- `patterns/django.md` — Django ORM
- `patterns/rails.md` — ActiveRecord
- `patterns/prisma.md` — Prisma Client
- `patterns/sqlalchemy.md` — SQLAlchemy ORM
- `patterns/gorm.md` — GORM
- `patterns/entity-framework.md` — EF Core

**Database additive patterns:**

- `patterns/postgresql.md` — PostgreSQL-specific: CTEs, BRIN, partial indexes, partitioning
- `patterns/sqlite.md` — SQLite-specific: WAL, PRAGMAs, WITHOUT ROWID, covering indexes

## Companion Script

`analyze-slow-queries.sh` — Multi-database slow query extractor.
Supports MySQL (Performance Schema), PostgreSQL (pg_stat_statements), and
SQLite (schema analysis + EXPLAIN QUERY PLAN). Run it before starting Phase 1.

## Quick Start

```bash
# === MySQL ===
./analyze-slow-queries.sh --dbtype mysql -h primary-host -u root -p pass -d mydb -o report.json

# === PostgreSQL ===
./analyze-slow-queries.sh --dbtype postgresql -h pg-host -U postgres -d mydb -o report.json

# === SQLite ===
./analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db -o report.json

# === Offline Mode (no DB access — user provides query log) ===
./analyze-slow-queries.sh --from-slow-log slow-sample.log --dbtype mysql
./analyze-slow-queries.sh --from-slow-log postgresql.log --dbtype postgresql

# === Auto-detect (tries mysql → postgresql) ===
./analyze-slow-queries.sh -h db-host -u user -d mydb -o report.json

# Then point the skill at the result + repository:
# "Analyze slow queries from report.json for our Laravel app at /path/to/repo"
```
