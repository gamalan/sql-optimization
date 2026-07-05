# MySQL Optimization Toolkit

Tools and guides for self-managed MySQL 8.0 — audit, configure, and
diagnose slow queries across popular frameworks.

## What's Inside

### `mysql-audit.sh` — Configuration Auditor & Optimizer

Connects to a running MySQL instance, audits 10 configuration areas
(InnoDB, connections, replication, temp tables, slow log, Performance
Schema, etc.), and generates an optimized `my.cnf` tailored to your
hardware and workload.

```bash
./mysql-audit.sh -h db-primary -u root -p secret -r primary -w oltp
```

Supports `--role primary|replica` and `--workload oltp|read-heavy|write-heavy|balanced`.

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

### `slow-query-analyzer/` — Agent Skill

An agent-agnostic skill that maps MySQL slow queries to framework ORM
anti-patterns and provides idiomatic fixes.

**Frameworks covered:** Laravel (Eloquent), Django (ORM), Rails
(ActiveRecord), Prisma, SQLAlchemy, GORM, Entity Framework.

**Three entry modes:**

| Mode | How |
|------|-----|
| Live | Agent queries Performance Schema directly |
| Offline | User provides `mysql-slow.log` file |
| Pasted | User pastes queries from logs, New Relic, pt-query-digest, etc. |

**Per query, the skill:** fingerprints → identifies ORM anti-pattern →
locates source code → recommends framework-idiomatic fix → rates severity.

```bash
./slow-query-analyzer/analyze-slow-queries.sh -h db-host -u root -d mydb -o report.json
```

## Quick Start

```bash
# 1. Audit your MySQL config
./mysql-audit.sh -h your-db-host -u root -r primary

# 2. Apply the generated mysql-optimized.cnf (review first!)

# 3. Extract and analyze slow queries
./slow-query-analyzer/analyze-slow-queries.sh -h your-db-host -u root -d mydb -o report.json

# 4. Point your agent at the results + your app repo
# "Analyze slow queries from report.json for our Laravel app"
```

## Requirements

- **mysql-audit.sh**: `mysql` or `mariadb` client, `bc`, `numfmt`
- **analyze-slow-queries.sh**: `mysql` client, `jq` (recommended),
  `python3` (for JSON assembly), `pt-query-digest` (optional, for slow
  log parsing)
- **MySQL**: 8.0+ with Performance Schema enabled
- **Agent skill**: works with any agent that reads SKILL.md files (Cursor,
  Claude Code, Pi, Codex, etc.)

## License

MIT — see [LICENSE](slow-query-analyzer/LICENSE).
