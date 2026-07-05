# Slow Query Framework Analyzer

An agent skill that analyzes MySQL slow queries and maps them to
framework-specific ORM code patterns — identifying the exact anti-pattern
(Laravel N+1, Django missing `select_related`, Rails missing `includes`,
Prisma missing `include`, etc.) and providing idiomatic fixes.

## What It Does

1. **Ingests slow queries** from MySQL Performance Schema, slow query log
   file, or pasted query text (supports offline mode when the agent can't
   access production DB)
2. **Fingerprints queries** and ranks them by impact
3. **Detects the framework** (Laravel, Django, Rails, Prisma, SQLAlchemy,
   GORM, Entity Framework) from the application repository
4. **Maps each fingerprint** to the exact ORM anti-pattern using
   framework-specific pattern databases
5. **Locates the code** in the application repository that produces each
   slow query
6. **Recommends idiomatic fixes** — framework-native code, not generic SQL
   rewrites
7. **Produces a prioritized report** with before/after code snippets,
   index DDL, and severity ratings

## Files

```
slow-query-analyzer/
├── SKILL.md                       # Agent skill instructions
├── analyze-slow-queries.sh        # MySQL extraction + fingerprinting script
├── patterns/                      # Framework-specific anti-pattern databases
│   ├── laravel.md                 # Eloquent & Query Builder
│   ├── django.md                  # Django ORM
│   ├── rails.md                   # ActiveRecord
│   ├── prisma.md                  # Prisma Client
│   ├── sqlalchemy.md              # SQLAlchemy ORM
│   ├── gorm.md                    # GORM
│   └── entity-framework.md        # EF Core
└── README.md                      # This file
```

## Frameworks Covered

| Framework | ORM | Language | Top Anti-Patterns Detected |
|-----------|-----|----------|--------------------------|
| Laravel | Eloquent | PHP | N+1, missing `with()`, offset pagination, `select *` |
| Django | Django ORM | Python | Missing `select_related`, `iterator()` not used, `__in` on large lists |
| Rails | ActiveRecord | Ruby | Missing `includes`, no counter cache, `find_each` not used |
| Prisma | Prisma Client | TypeScript | Missing `include`, no `select`, no cursor pagination |
| SQLAlchemy | SQLAlchemy ORM | Python | Missing `selectinload`, lazy='select' default, session issues |
| GORM | GORM | Go | Missing `Preload`, no `FindInBatches`, missing indexes |
| Entity Framework | EF Core | C# | Missing `Include`, no `AsSplitQuery`, no `AsNoTracking` |

## Quick Start

### Live Mode (agent has DB access)

```bash
# Extract top 30 slow queries from MySQL
./analyze-slow-queries.sh -h db-primary -u root -p secret -d mydb -o report.json

# Then in your agent prompt:
"Analyze slow queries from report.json for our Laravel app at /path/to/repo"
```

### Offline Mode (no DB access — user provides the log)

```bash
# User exports the slow query log from production:
# cat /var/log/mysql/mysql-slow.log | head -5000 > slow-sample.log

# Agent analyzes it locally:
./analyze-slow-queries.sh --from-slow-log slow-sample.log -o report.json
```

### Pasted Query Mode (user provides queries directly)

```
User: "Our Django app is slow. Here are the queries from pt-query-digest:
  # Rank 1: 245s total, SELECT * FROM app_post WHERE author_id = ?
  # Rank 2: 180s total, SELECT COUNT(*) FROM app_comment WHERE post_id = ?
  ..."

Agent: fingerprints, maps to Django N+1 patterns, finds missing
select_related, recommends fixes.
```

## Example Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Slow Query Analysis Report — Laravel App
  Database: mydb   |   Framework: Laravel 11 (Eloquent)
  Queries Analyzed: 30   |   Critical: 4   High: 8
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔴 CRITICAL — N+1: posts relation on User model
  Queries: 12,345/hr, avg 245ms, total 840s
  Fix:    User::with('posts') in UserController:42
  Impact: ~98% reduction in query count

🔴 CRITICAL — Missing Index: orders.status + created_at
  Queries: 456/hr, avg 1.2s, total 547s
  Fix:    CREATE INDEX idx_orders_status_created ON orders (status, created_at)
  Impact: Index scan instead of full table scan

🟠 HIGH — Offset pagination on posts
  Queries: 2,345/hr, avg 320ms
  Fix:    Use cursorPaginate() instead of paginate()
  Impact: ~70% reduction in rows examined

...

No changes have been applied. All fixes require manual review and approval.
```

## Related Tools

- Companion to `mysql-audit.sh` for server-level configuration
- Pairs with `MYSQL-OPTIMIZATION-GUIDE.md` for general MySQL optimization
- Uses PlanetScale-inspired SQLCommenter tagging for query attribution
