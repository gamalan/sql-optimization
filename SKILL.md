---
name: sql-optimization
description: Audit and optimize MySQL, PostgreSQL, and SQLite — configure instances, diagnose slow queries, and apply framework-idiomatic fixes (Laravel, Django, Rails, Prisma, SQLAlchemy, GORM, EF Core). Includes indexing expertise based on Use The Index, Luke!
---

# SQL Optimization Toolkit

Audit database configuration, extract and diagnose slow queries, and
apply framework-idiomatic fixes for MySQL, PostgreSQL, and SQLite.

## Tools

### Database Auditors (run first to check server config)

These scripts connect to a running instance and generate an optimized
configuration file + audit report. Run them from the repo root:

| Script | Database | Usage |
|--------|----------|-------|
| `mysql-audit.sh` | MySQL 8.0+ | `./mysql-audit.sh -h HOST -u USER -p PASS -r primary -w oltp` |
| `postgresql-audit.sh` | PostgreSQL 14+ | `./postgresql-audit.sh -h HOST -U USER -d DB -r primary -w oltp` |
| `sqlite-audit.sh` | SQLite 3.x | `./sqlite-audit.sh -d database.db -w web` |

Each supports `--role primary|replica` and workload profiles:

| Auditor | Workloads |
|---------|-----------|
| MySQL | `oltp`, `read-heavy`, `write-heavy`, `balanced` |
| PostgreSQL | `oltp`, `analytics`, `balanced`, `read-heavy` |
| SQLite | `web`, `mobile`, `embedded`, `analytics`, `read-heavy` |

**Output per auditor:**

- Optimized config (`mysql-optimized.cnf`, `postgresql-optimized.conf`, `sqlite-optimized-pragmas.sql`)
- Full audit report (`*-audit-report.txt`)

### Slow Query Analyzer (run after audit)

Extracts and fingerprints slow queries, maps them to ORM anti-patterns,
and recommends framework-idiomatic fixes. See `skills/slow-query-analyzer/` for
the full skill document.

```bash
# MySQL
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype mysql -h HOST -u USER -d DB -o report.json

# PostgreSQL
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype postgresql -h HOST -U USER -d DB -o report.json

# SQLite
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db -o report.json
```

Frameworks covered: Laravel, Django, Rails, Prisma, SQLAlchemy, GORM, Entity Framework.

### Indexing Expertise (skills/index-luke/)

Teaches SQL indexing principles from Markus Winand's "Use The Index, Luke!":
composite index column ordering, pipelined ORDER BY, keyset pagination,
covering indexes, join indexing.

## Typical Workflow

1. **Audit config**: run the auditor for your database — it finds misconfigured
   memory, I/O, connections, and generates an optimized config.
2. **Bash the auditor**: `./<db>-audit.sh ...` — the script connects, audits,
   and writes config + report files.
3. **Apply config**: review, then apply the generated config. Most settings
   take effect with `SET GLOBAL`/`pg_ctl reload`; a few need restart.
4. **Extract slow queries**: run `analyze-slow-queries.sh` to get the top N
   slow queries as JSON.
5. **Analyze with the skill**: pass the JSON report + your app repo to the
   agent. It fingerprints each query, maps to ORM code, and recommends fixes.
6. **Apply fixes**: add indexes, add eager loading, fix N+1, tune queries.

## Example Session

> "Audit our PostgreSQL config at db-primary, then analyze slow queries
> for our Django app at ~/project/"

The agent will:

1. Run `./postgresql-audit.sh -h db-primary -U postgres -d mydb -r primary`
2. Review the generated `postgresql-optimized.conf` and report
3. Run `./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype postgresql -h db-primary -U postgres -d mydb -o report.json`
4. Cross-reference queries against `skills/slow-query-analyzer/patterns/django.md`
   and `skills/slow-query-analyzer/patterns/postgresql.md`
5. Search the Django app for matching ORM calls
6. Report findings with before/after code snippets

## Files

```
.
├── mysql-audit.sh                    # MySQL config auditor
├── postgresql-audit.sh               # PostgreSQL config auditor
├── sqlite-audit.sh                   # SQLite PRAGMA auditor
├── MYSQL-OPTIMIZATION-GUIDE.md       # Deep-dive MySQL tuning guide
├── README.md                         # Full project readme
├── docs/index-luke-lessons.md        # Indexing lessons from Use The Index, Luke!
├── skills/index-luke/                # Indexing expertise skill
└── skills/slow-query-analyzer/              # Multi-DB slow query analyzer
    ├── analyze-slow-queries.sh       # Extraction script
    ├── SKILL.md                      # Full skill documentation
    └── patterns/                     # Framework + DB anti-patterns
        ├── laravel.md
        ├── django.md
        ├── rails.md
        ├── prisma.md
        ├── sqlalchemy.md
        ├── gorm.md
        ├── entity-framework.md
        ├── postgresql.md             # PG-specific patterns
        └── sqlite.md                 # SQLite-specific patterns
```
