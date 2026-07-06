# SQL Optimization Toolkit

Database audit and optimization scripts for MySQL, PostgreSQL, and SQLite.
Audit configuration, identify issues, and generate optimized configs for
your hardware and workload.

## Database Auditors

| Script | Database | What It Audits |
|--------|----------|----------------|
| `mysql-audit.sh` | MySQL 8.0 | InnoDB, replication, connections, temp tables, slow log, Performance Schema |
| `postgresql-audit.sh` | PostgreSQL 14+ | Memory, WAL, autovacuum, query planner, replication, logging, extensions |
| `sqlite-audit.sh` | SQLite 3.x | PRAGMAs (journal, cache, sync), indexes, schema, integrity, fragmentation |

Each auditor connects to a running instance (or database file), runs a full diagnostic,
and generates:

1. **An optimized configuration file** (`my.cnf`, `postgresql.conf`, or PRAGMA SQL)
2. **A detailed audit report** with recommendations

## What's Inside

### `mysql-audit.sh` — MySQL Configuration Auditor & Optimizer

Connects to a running MySQL instance, audits 10 configuration areas
(InnoDB, connections, replication, temp tables, slow log, Performance
Schema, etc.), and generates an optimized `my.cnf` tailored to your
hardware and workload.

```bash
./mysql-audit.sh -h db-primary -u root -p secret -r primary -w oltp
```

Supports `--role primary|replica` and `--workload oltp|read-heavy|write-heavy|balanced`.

### `postgresql-audit.sh` — PostgreSQL Configuration Auditor & Optimizer

Connects to a running PostgreSQL instance (primary or replica), audits 10
configuration areas (shared_buffers, WAL, autovacuum, query planner, replication,
logging, extensions), and generates an optimized `postgresql.conf`.

```bash
./postgresql-audit.sh -h db-primary -U postgres -d mydb -r primary -w oltp
```

Supports `--role primary|replica` and `--workload oltp|analytics|balanced|read-heavy`.

**Audited areas:**

- Memory (shared_buffers, work_mem, maintenance_work_mem, effective_cache_size)
- WAL & checkpoints (wal_level, max_wal_size, checkpoint_timeout, synchronous_commit)
- Autovacuum (dead tuples, max_workers, scale factor, cost limits, TXID age)
- Connections (max_connections, idle/active breakdown, connection memory risk)
- Query planner (random_page_cost, effective_io_concurrency, JIT, parallel query)
- Replication (streaming replication lag, WAL senders, replication slots, hot_standby)
- Logging & monitoring (slow query log, pg_stat_statements, auto_explain, lock_waits)
- Database stats (table sizes, cache hit ratios, dead tuples, index scan ratio)
- Index analysis (duplicate, invalid, unused, scan ratio)

### `sqlite-audit.sh` — SQLite Database Auditor & Optimizer

Analyzes a SQLite database file, audits PRAGMA settings, indexes, fragmentation,
and generates optimized PRAGMA recommendations for your workload.

```bash
./sqlite-audit.sh -d myapp.db -w web
```

Supports `--workload web|mobile|embedded|analytics|read-heavy`.

**Audited areas:**

- System info (SQLite version, compile options, file size, page count, fragmentation)
- PRAGMAs (journal_mode, synchronous, cache_size, page_size, mmap_size, temp_store,
  auto_vacuum, foreign_keys, busy_timeout, secure_delete, wal_autocheckpoint)
- Schema analysis (tables, indexes, auto-indexes, triggers, views, WITHOUT ROWID)
- Index analysis (per-table index counts, tables missing indexes, space usage)
- Table statistics (row counts via sqlite_stat1, STAT4 availability)
- Query planner settings
- Integrity checks (integrity_check, foreign_key_check)

### `MYSQL-OPTIMIZATION-GUIDE.md` — Comprehensive Guide

Covers the full read/write optimization stack:

- InnoDB tuning (buffer pool, redo logs, flush strategy, IO capacity)
- Replication architecture (GTID, parallel workers, failover)
- Read/write splitting (app-level + ProxySQL)
- Connection pooling (HikariCP, SQLAlchemy, Prisma, GORM sizing)
- Indexing strategy (composite index rules, finding unused indexes)
- **Indexing principles from [Use The Index, Luke!](https://use-the-index-luke.com/)** (see `docs/index-luke-lessons.md`)
- Query optimization (EXPLAIN hierarchy, N+1 → batch, OFFSET → cursor)
- SQLCommenter-style query tagging for attribution
- Monitoring (metrics, alert thresholds, pt-query-digest, DIY Insights)
- Backup & recovery (XtraBackup, PITR, restore drills)
- PlanetScale-inspired practices adapted for self-managed MySQL

### `skills/index-luke/` — Indexing Expert Skill

An agent-agnostic skill based on Markus Winand's
[Use The Index, Luke!](https://use-the-index-luke.com/). Teaches and
diagnoses SQL indexing: composite index column ordering, pipelined ORDER
BY, keyset pagination, covering indexes, join indexing, and 10 indexed
lessons covering the full body of work.

### `skills/slow-query-analyzer/` — Multi-Database Slow Query Analyzer

An agent-agnostic skill that extracts slow queries from MySQL, PostgreSQL, or
SQLite, fingerprints them, and maps each to framework ORM anti-patterns with
idiomatic fixes.

**Databases supported:** MySQL (Performance Schema), PostgreSQL (pg_stat_statements),
SQLite (schema + EXPLAIN QUERY PLAN).

**Frameworks covered:** Laravel (Eloquent), Django (ORM), Rails (ActiveRecord),
Prisma, SQLAlchemy, GORM, Entity Framework.

**Database-specific additive patterns:**

| Database | Pattern File | Key Concerns |
|----------|-------------|--------------|
| PostgreSQL | `patterns/postgresql.md` | CTEs, BRIN indexes, parallel workers, partitioning |
| SQLite | `patterns/sqlite.md` | WAL tuning, PRAGMA optimization, WITHOUT ROWID, covering indexes |

**Four entry modes:**

| Mode | MySQL | PostgreSQL | SQLite |
|------|-------|------------|--------|
| Live | Queries Performance Schema | Queries pg_stat_statements | Analyzes .db file schema |
| Offline | Parses `mysql-slow.log` | Parses PG logs (pgbadger) | N/A (file is always available) |
| Pasted | User pastes from monitoring tools | User pastes from monitoring tools | User pastes EXPLAIN QUERY PLAN output |
| Auto-detect | `--dbtype mysql` or omit for auto-detect | `--dbtype postgresql` | `--dbtype sqlite -f my.db` |

**Per query, the skill:** fingerprints → identifies ORM anti-pattern →
locates source code → recommends framework-idiomatic fix → rates severity.

```bash
# MySQL
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype mysql -h db-host -u root -d mydb -o report.json

# PostgreSQL
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype postgresql -h db-host -U postgres -d mydb -o report.json

# SQLite
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db -o report.json
```

## Quick Start

```bash
# MySQL: Audit config + analyze slow queries
./mysql-audit.sh -h your-db-host -u root -r primary
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype mysql -h your-db-host -u root -d mydb -o report.json

# PostgreSQL: Audit config + analyze slow queries
./postgresql-audit.sh -h your-db-host -U postgres -d mydb -r primary
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype postgresql -h your-db-host -U postgres -d mydb -o report.json

# SQLite: Audit PRAGMAs + analyze schema/queries
./sqlite-audit.sh -d myapp.db -w web
./skills/slow-query-analyzer/analyze-slow-queries.sh --dbtype sqlite -f myapp.db -o report.json

# Apply the generated configs (review first!)
# MySQL:   cp mysql-optimized.cnf /etc/mysql/my.cnf && systemctl restart mysql
# PostgreSQL: cp postgresql-optimized.conf $PGDATA/postgresql.conf && pg_ctl reload
# SQLite:  sqlite3 myapp.db < sqlite-optimized-pragmas.sql
```

## Installing the Agent Skills

This repo contains a **root `SKILL.md`** that bundles the entire toolkit — audit
scripts, slow query analyzer, and indexing expertise — into one installable skill.
The agent gets access to all tools when you install from the repo root.

```bash
# 1. Clone the repo
git clone https://github.com/gamalan/sql-optimization.git
cd sql-optimization

# === Pi (Recommended: install the root skill — everything included) ===
pi install . --name sql-optimization

# Or from GitHub directly:
pi install github:gamalan/sql-optimization --name sql-optimization

# === Pi (Individual skills if you only need one) ===
pi install ./skills/slow-query-analyzer --name slow-query-analyzer
pi install ./skills/index-luke --name index-luke
# Note: individual installs only include that subdirectory — audit
# scripts at repo root won't be available to the agent.

# === Claude Code ===
# Copy the whole repo into ~/.claude/skills/:
cp -r . ~/.claude/skills/sql-optimization
# Then in Claude Code: /add-skill sql-optimization

# === Cursor / Codex / Other Agents ===
# Point your agent's skill directory at the cloned repo root.
# The agent discovers the root SKILL.md + all sub-skills.
```

Once installed, invoke the skills in natural language:

> "Audit our PostgreSQL config at db-primary and check for slow queries
> in our Django app"

> "Explain why this query is slow using index-luke principles"

> "Run the MySQL auditor against our primary and suggest config changes"

## Requirements

| Tool | Required |
|------|----------|
| **mysql-audit.sh** | `mysql` or `mariadb` client, `bc`, `numfmt` |
| **postgresql-audit.sh** | `psql` client (postgresql-client) |
| **sqlite-audit.sh** | `sqlite3` CLI (usually pre-installed) |
| **analyze-slow-queries.sh (MySQL)** | `mysql` client, `jq`, `python3`, `pt-query-digest` (optional) |
| **analyze-slow-queries.sh (PostgreSQL)** | `psql` client, `jq`, `python3`, `pgbadger` (optional) |
| **analyze-slow-queries.sh (SQLite)** | `sqlite3` CLI, `jq`, `python3` |
| **MySQL** | 8.0+ with Performance Schema enabled |
| **PostgreSQL** | 14+ with pg_stat_statements extension enabled |
| **SQLite** | 3.x (3.25+ for WAL, 3.31+ for generated columns) |
| **Agent skill** | works with any agent that reads SKILL.md files (Cursor, Claude Code, Pi, Codex, etc.) |

## License

MIT — see [LICENSE](skills/slow-query-analyzer/LICENSE).
