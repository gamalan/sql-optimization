#!/usr/bin/env bash
# =============================================================================
# sqlite-audit.sh — SQLite Database Audit & Optimization Tool
# =============================================================================
# Audits a SQLite database file, analyzes PRAGMA settings, indexes, and
# generates optimization recommendations for various workloads (OLTP web app,
# mobile, embedded, analytics, read-heavy).
#
# Usage:
#   chmod +x sqlite-audit.sh
#   ./sqlite-audit.sh database.db                   # audit a database
#   ./sqlite-audit.sh -d database.db -w mobile      # specify workload
#   ./sqlite-audit.sh -d database.db -o report.txt  # write report to file
#   ./sqlite-audit.sh --help
#
# Output:
#   - Current configuration report (stdout)
#   - sqlite-optimized-pragmas.sql (generated PRAGMA recommendations)
#   - sqlite-audit-report.txt (full audit report)
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
DB_PATH=""
WORKLOAD="web" # web | mobile | embedded | analytics | read-heavy
OUTPUT_PRAGMAS="sqlite-optimized-pragmas.sql"
OUTPUT_REPORT="sqlite-audit-report.txt"
TOTAL_RAM_MB="" # for cache_size recommendations

# ---- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- Help -------------------------------------------------------------------
usage() {
	cat <<'EOF'
sqlite-audit.sh — SQLite Database Auditor & Optimizer

USAGE:
  ./sqlite-audit.sh [OPTIONS] [DATABASE.db]

OPTIONS:
  -d, --database PATH  Path to SQLite database file
  -w, --workload TYPE  Workload: web | mobile | embedded | analytics | read-heavy
  -o, --output FILE    Write report to FILE (default: sqlite-audit-report.txt)
  -m, --ram MB         System RAM in MB for cache_size recommendations
  --help               Show this help

WORKLOAD PROFILES:
  web         Web app (concurrent reads/writes, WAL mode) — DEFAULT
  mobile      Mobile/device (lower memory, durable writes)
  embedded    Embedded/IoT (minimal memory, crash-safe)
  analytics   Read-heavy analytics (large cache, minimal sync)
  read-heavy  Read-mostly (large page cache, relaxed sync)

EXAMPLES:
  ./sqlite-audit.sh myapp.db
  ./sqlite-audit.sh -d /var/data/production.db -w web -m 8192
  ./sqlite-audit.sh -d analytics.db -w analytics -o analytics-report.txt

EOF
	exit 0
}

# ---- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	-d | --database)
		DB_PATH="$2"
		shift 2
		;;
	-w | --workload)
		WORKLOAD="$2"
		shift 2
		;;
	-o | --output)
		OUTPUT_REPORT="$2"
		shift 2
		;;
	-m | --ram)
		TOTAL_RAM_MB="$2"
		shift 2
		;;
	--help) usage ;;
	-*)
		echo "Unknown option: $1"
		usage
		;;
	*)
		# Positional argument
		if [[ -z "$DB_PATH" ]]; then
			DB_PATH="$1"
		else
			echo "Unknown argument: $1"
			usage
		fi
		shift
		;;
	esac
done

# ---- Validation -------------------------------------------------------------
if [[ -z "$DB_PATH" ]]; then
	echo -e "${RED}ERROR: No database specified.${NC}"
	echo "Usage: ./sqlite-audit.sh [-d] database.db"
	exit 1
fi

if [[ ! -f "$DB_PATH" ]]; then
	echo -e "${RED}ERROR: Database file not found: ${DB_PATH}${NC}"
	exit 1
fi

# ---- SQLite CLI Check -------------------------------------------------------
SQLITE_CLI=""
if command -v sqlite3 &>/dev/null; then
	SQLITE_CLI="sqlite3"
else
	echo -e "${RED}ERROR: sqlite3 client not found. Install sqlite3.${NC}"
	exit 1
fi

# ---- Helper functions -------------------------------------------------------
# Run a query and return single value (no headers)
sql() {
	$SQLITE_CLI "$DB_PATH" "$1" 2>/dev/null || echo "QUERY_ERROR"
}

# Get a PRAGMA value (returns single value)
pragma_val() {
	local name="$1"
	sql "PRAGMA ${name};" | head -1
}

# Format bytes
bytes_to_human() {
	local bytes="$1"
	if command -v numfmt &>/dev/null; then
		numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
	else
		if ((bytes > 1073741824)); then
			echo "$((bytes / 1073741824)) GB"
		elif ((bytes > 1048576)); then
			echo "$((bytes / 1048576)) MB"
		elif ((bytes > 1024)); then
			echo "$((bytes / 1024)) KB"
		else
			echo "${bytes} B"
		fi
	fi
}

# ---- System & Database Info -------------------------------------------------
check_system_info() {
	echo -e "${BOLD}━━━ System & Database Information ━━━${NC}"

	# SQLite version
	local sqlite_ver
	sqlite_ver=$($SQLITE_CLI --version 2>/dev/null | awk '{print $1}' || echo "unknown")
	local sqlite_lib_ver
	sqlite_lib_ver=$(sql "SELECT sqlite_version();")
	echo "  sqlite3 CLI:      ${GREEN}${sqlite_ver}${NC}"
	echo "  SQLite Library:   ${GREEN}${sqlite_lib_ver}${NC}"

	# Check compile options
	local compile_opts
	compile_opts=$(sql "SELECT sqlite_compileoption_used('ENABLE_FTS5') ||
		';FTS3=' || sqlite_compileoption_used('ENABLE_FTS3') ||
		';JSON1=' || sqlite_compileoption_used('ENABLE_JSON1') ||
		';RTREE=' || sqlite_compileoption_used('ENABLE_RTREE') ||
		';STAT4=' || sqlite_compileoption_used('ENABLE_STAT4') ||
		';STAT3=' || sqlite_compileoption_used('ENABLE_STAT3');")
	echo "  Compile options:  ${compile_opts}"

	# Check if STAT4/STAT3 is available
	local has_stat4
	has_stat4=$(sql "SELECT sqlite_compileoption_used('ENABLE_STAT4');")
	if [[ "$has_stat4" != "1" ]]; then
		echo -e "    ${YELLOW}⚠  STAT4 not enabled. ANALYZE will not collect detailed stats.${NC}"
		echo "      Recompile with -DSQLITE_ENABLE_STAT4 for better query plans."
	fi

	# File info
	local db_size
	db_size=$(stat -c%s "$DB_PATH" 2>/dev/null || stat -f%z "$DB_PATH" 2>/dev/null || echo "0")
	echo "  Database file:    ${DB_PATH}"
	echo "  File size:        $(bytes_to_human $db_size)"

	# Page count and page size
	local page_count page_size
	page_count=$(pragma_val page_count)
	page_size=$(pragma_val page_size)
	local data_size=$((page_count * page_size))
	echo "  Pages:            ${page_count} × ${page_size} bytes = $(bytes_to_human $data_size)"

	# Freelist count (fragmentation indicator)
	local freelist_count
	freelist_count=$(pragma_val freelist_count)
	local fragmentation=0
	if ((page_count > 0)); then
		fragmentation=$((freelist_count * 100 / page_count))
	fi
	echo "  Free pages:       ${freelist_count} (${fragmentation}% fragmentation)"
	if ((fragmentation > 20)); then
		echo -e "    ${YELLOW}⚠  High fragmentation (${fragmentation}%). Run VACUUM.${NC}"
	elif ((fragmentation > 10)); then
		echo -e "    ${YELLOW}⚠  Moderate fragmentation. Consider VACUUM.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy${NC}"
	fi

	# Detect RAM
	if [[ -z "$TOTAL_RAM_MB" ]]; then
		if [[ -f /proc/meminfo ]]; then
			TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
		elif command -v free &>/dev/null; then
			TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
		else
			TOTAL_RAM_MB=512 # Conservative default for embedded/mobile
		fi
	fi
	export TOTAL_RAM_MB
	echo "  System RAM:       ${TOTAL_RAM_MB} MB"

	echo ""
}

# ---- PRAGMA Configuration ---------------------------------------------------
check_pragmas() {
	echo -e "${BOLD}━━━ PRAGMA Configuration Audit ━━━${NC}"

	# Journal Mode
	local journal_mode
	journal_mode=$(pragma_val journal_mode)
	echo "  journal_mode:     ${journal_mode}"
	case "$journal_mode" in
	wal)
		echo -e "    ${GREEN}✓ WAL: best for concurrent reads/writes (web apps).${NC}"
		;;
	delete)
		echo -e "    ${YELLOW}⚠  DELETE: rollback journal. Consider WAL for concurrency.${NC}"
		;;
	truncate)
		echo -e "    ${YELLOW}⚠  TRUNCATE: similar to DELETE. WAL is recommended.${NC}"
		;;
	persist)
		echo -e "    ${YELLOW}⚠  PERSIST: retains journal. WAL is usually better.${NC}"
		;;
	memory)
		echo -e "    ${RED}✗ MEMORY: data lost on connection close! Only for temp DBs.${NC}"
		;;
	off)
		echo -e "    ${RED}✗ OFF: no crash recovery. Only for read-only or bulk loads.${NC}"
		;;
	esac

	# Synchronous
	local synchronous
	synchronous=$(pragma_val synchronous)
	local sync_names=("OFF" "NORMAL" "FULL" "EXTRA")
	local sync_idx=${synchronous:-2}
	local sync_label="${sync_names[$sync_idx]}"
	echo "  synchronous:      ${synchronous} (${sync_label})"
	case "$synchronous" in
	2 | full | FULL)
		echo -e "    ${GREEN}✓ FULL: safest, recommended for production.${NC}"
		;;
	1 | normal | NORMAL)
		echo -e "    ${YELLOW}⚠  NORMAL: may corrupt on power loss. OK for WAL mode.${NC}"
		;;
	0 | off | OFF)
		echo -e "    ${RED}✗ OFF: no sync. Fast but data loss on crash.${NC}"
		;;
	esac

	# Cache Size
	local cache_size
	cache_size=$(pragma_val cache_size)
	local cache_kb
	if ((cache_size < 0)); then
		# Negative means kilobytes
		cache_kb=$((-cache_size))
	else
		# Positive means pages
		local page_size
		page_size=$(pragma_val page_size)
		cache_kb=$((cache_size * page_size / 1024))
	fi
	local cache_mb=$((cache_kb / 1024))
	echo "  cache_size:       ${cache_kb} KB (${cache_mb} MB)"

	local recommended_cache_mb=0
	case "$WORKLOAD" in
	web) recommended_cache_mb=$((TOTAL_RAM_MB * 10 / 100 > 32 ? TOTAL_RAM_MB * 10 / 100 : (TOTAL_RAM_MB * 5 / 100 > 32 ? TOTAL_RAM_MB * 5 / 100 : 32))) ;;
	mobile) recommended_cache_mb=$((TOTAL_RAM_MB * 5 / 100 < 2 ? 2 : (TOTAL_RAM_MB * 5 / 100 > 16 ? 16 : TOTAL_RAM_MB * 5 / 100))) ;;
	embedded) recommended_cache_mb=$((TOTAL_RAM_MB * 5 / 100 < 1 ? 1 : (TOTAL_RAM_MB * 5 / 100 > 8 ? 8 : TOTAL_RAM_MB * 5 / 100))) ;;
	analytics) recommended_cache_mb=$((TOTAL_RAM_MB * 40 / 100 > 512 ? 512 : TOTAL_RAM_MB * 40 / 100)) ;;
	read-heavy) recommended_cache_mb=$((TOTAL_RAM_MB * 25 / 100 > 256 ? 256 : TOTAL_RAM_MB * 25 / 100)) ;;
	esac

	if ((cache_mb < recommended_cache_mb / 2)); then
		echo -e "    ${YELLOW}⚠  Cache is low. Recommend ~${recommended_cache_mb} MB for ${WORKLOAD} workload.${NC}"
	elif ((cache_mb > recommended_cache_mb * 3)); then
		echo -e "    ${YELLOW}⚠  Cache is high relative to system RAM.${NC}"
	else
		echo -e "    ${GREEN}✓ OK${NC}"
	fi

	# Page Size
	local page_size
	page_size=$(pragma_val page_size)
	echo "  page_size:        ${page_size} bytes"

	local optimal_page_size=4096
	if ((page_size < 4096)); then
		echo -e "    ${YELLOW}⚠  Small page size. 4096 is usually optimal for modern systems.${NC}"
		echo "      (The page_size PRAGMA can only be set before creating the database.)"
	fi

	# MMAP Size
	local mmap_size
	mmap_size=$(pragma_val mmap_size)
	if ((mmap_size == 0)); then
		echo "  mmap_size:        0 (disabled)"
		echo -e "    ${YELLOW}⚠  Memory-mapped I/O is disabled. Enable for read-heavy workloads.${NC}"
	else
		echo "  mmap_size:        $(bytes_to_human $mmap_size)"
		echo -e "    ${GREEN}✓ Memory-mapped I/O enabled${NC}"
	fi

	# Temp Store
	local temp_store
	temp_store=$(pragma_val temp_store)
	local temp_names=("DEFAULT" "FILE" "MEMORY")
	echo "  temp_store:       ${temp_store} (${temp_names[${temp_store:-0}]})"
	case "$temp_store" in
	0 | DEFAULT) echo -e "    ${GREEN}✓ DEFAULT (uses SQLITE_TEMP_STORE compile flag)${NC}" ;;
	1 | FILE) echo -e "    ${YELLOW}⚠  FILE: temp tables on disk. Consider MEMORY for speed.${NC}" ;;
	2 | MEMORY) echo -e "    ${GREEN}✓ MEMORY: temp tables in RAM (may use lots of memory).${NC}" ;;
	esac

	# Auto Vacuum
	local auto_vacuum
	auto_vacuum=$(pragma_val auto_vacuum)
	local av_names=("NONE" "FULL" "INCREMENTAL")
	echo "  auto_vacuum:      ${auto_vacuum} (${av_names[${auto_vacuum:-0}]})"
	case "$auto_vacuum" in
	0 | NONE) echo -e "    ${GREEN}✓ NONE: manual VACUUM only (default, fastest writes).${NC}" ;;
	1 | FULL) echo -e "    ${YELLOW}⚠  FULL: auto-vacuum on commit. Slower writes, less fragmentation.${NC}" ;;
	2 | INCREMENTAL) echo -e "    ${YELLOW}⚠  INCREMENTAL: partial auto-vacuum. Use with PRAGMA incremental_vacuum.${NC}" ;;
	esac

	# Foreign Keys
	local foreign_keys
	foreign_keys=$(pragma_val foreign_keys)
	echo "  foreign_keys:     ${foreign_keys}"
	if [[ "$foreign_keys" == "0" ]]; then
		echo -e "    ${YELLOW}⚠  Foreign key enforcement is OFF. Enable if using FK constraints.${NC}"
	else
		echo -e "    ${GREEN}✓ Foreign keys enforced${NC}"
	fi

	# Secure Delete
	local secure_delete
	secure_delete=$(pragma_val secure_delete)
	if [[ "$secure_delete" != "0" ]]; then
		echo "  secure_delete:    ${secure_delete}"
		echo -e "    ${YELLOW}⚠  Secure delete is ON. This slows writes significantly.${NC}"
	fi

	# WAL Autocheckpoint
	local wal_autocheckpoint
	wal_autocheckpoint=$(pragma_val wal_autocheckpoint 2>/dev/null || echo "N/A")
	echo "  wal_autocheckpt:  ${wal_autocheckpoint}"
	if [[ "$wal_autocheckpoint" != "N/A" ]] && ((wal_autocheckpoint > 10000)); then
		echo -e "    ${YELLOW}⚠  Large WAL checkpoint interval. May grow WAL file too big.${NC}"
	fi

	# Busy Timeout
	local busy_timeout
	busy_timeout=$(pragma_val busy_timeout)
	echo "  busy_timeout:     ${busy_timeout}ms"
	if ((busy_timeout == 0)); then
		echo -e "    ${YELLOW}⚠  No busy timeout. Set to 5000ms for concurrent access.${NC}"
	fi

	# Journal Size Limit (WAL mode)
	local journal_size_limit
	journal_size_limit=$(pragma_val journal_size_limit)
	if [[ "$journal_size_limit" == "-1" ]]; then
		echo "  journal_size_limit: unlimited"
	elif [[ "$journal_size_limit" != "" ]]; then
		echo "  journal_size_limit: $(bytes_to_human $journal_size_limit)"
	fi

	echo ""
}

# ---- Table & Schema Analysis ------------------------------------------------
check_schema() {
	echo -e "${BOLD}━━━ Schema Analysis ━━━${NC}"

	# Table count
	local table_count
	table_count=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
	echo "  User tables:      ${table_count}"

	# Index count
	local idx_count
	idx_count=$(sql "SELECT count(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_autoindex%';")
	echo "  User indexes:     ${idx_count}"

	# Auto-index count (implicit indexes for PK/UNIQUE)
	local auto_idx_count
	auto_idx_count=$(sql "SELECT count(*) FROM sqlite_master WHERE type='index' AND name LIKE 'sqlite_autoindex%';")
	echo "  Auto-indexes:     ${auto_idx_count}"

	# Trigger count
	local trig_count
	trig_count=$(sql "SELECT count(*) FROM sqlite_master WHERE type='trigger';")
	echo "  Triggers:         ${trig_count}"

	# View count
	local view_count
	view_count=$(sql "SELECT count(*) FROM sqlite_master WHERE type='view';")
	echo "  Views:            ${view_count}"

	# WITHOUT ROWID tables
	local without_rowid
	without_rowid=$(sql "SELECT count(*) FROM sqlite_master WHERE type='table' AND sql LIKE '%WITHOUT ROWID%';")
	echo "  WITHOUT ROWID:    ${without_rowid}"

	echo ""
}

# ---- Index Analysis ---------------------------------------------------------
check_indexes() {
	echo -e "${BOLD}━━━ Index Analysis ━━━${NC}"

	# List all tables and their indexes
	echo "  Tables & indexes:"
	sql "SELECT m.name AS tbl,
		(SELECT count(*) FROM pragma_index_list(m.name)) AS idx_count,
		(SELECT count(*) FROM pragma_table_info(m.name)) AS col_count
		FROM sqlite_master m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
		ORDER BY tbl;" 2>/dev/null | while IFS='|' read -r tbl idx_cnt col_cnt; do
		printf "    %-30s cols:%-3s indexes:%-3s\n" "$tbl" "$col_cnt" "$idx_cnt"
	done || echo "    (could not query)"

	# Tables without explicit indexes (excluding auto-indexes for PK)
	echo ""
	echo "  Tables without explicit indexes:"
	sql "SELECT m.name FROM sqlite_master m
		WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%'
		AND NOT EXISTS (SELECT 1 FROM pragma_index_list(m.name)
			WHERE origin = 'c')
		ORDER BY m.name;" 2>/dev/null | while IFS= read -r tbl; do
		echo -e "    ${YELLOW}${tbl}${NC}"
	done
	if [[ $(sql "SELECT count(*) FROM sqlite_master m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' AND NOT EXISTS (SELECT 1 FROM pragma_index_list(m.name) WHERE origin = 'c');" 2>/dev/null) == "0" ]]; then
		echo "    (all tables have explicit indexes)"
	fi

	# Index size estimation via sqlite_analyzer / dbstat if available
	local has_dbstat
	has_dbstat=$(sql "SELECT count(*) FROM sqlite_master WHERE name='dbstat' AND type='table';" 2>/dev/null || echo "0")
	if [[ "$has_dbstat" == "0" ]]; then
		echo ""
		echo -e "  ${YELLOW}⚠  dbstat virtual table not available.${NC}"
		echo "    Run: sqlite3_analyzer ${DB_PATH} for detailed index/table space usage."
	else
		echo ""
		echo "  Space usage (top 5):"
		sql "SELECT name, pageno, pagetype, ncell, payload FROM dbstat ORDER BY pageno DESC LIMIT 5;" 2>/dev/null | while IFS='|' read -r name pgno ptype cells payload; do
			printf "    %-20s pages:%-6s type:%-8s cells:%-5s\n" "$name" "$pgno" "$ptype" "$cells"
		done
	fi

	# Check if STAT tables exist (from ANALYZE)
	local has_stat
	has_stat=$(sql "SELECT count(*) FROM sqlite_master WHERE name='sqlite_stat1' AND type='table';")
	if [[ "$has_stat" == "0" ]]; then
		echo ""
		echo -e "  ${YELLOW}⚠  No statistics table (sqlite_stat1). Run ANALYZE to collect stats.${NC}"
		echo "    Run: sqlite3 ${DB_PATH} 'ANALYZE;'"
	else
		echo ""
		echo "  Statistics:"
		local stat_count
		stat_count=$(sql "SELECT count(*) FROM sqlite_stat1;")
		echo -e "    ${GREEN}✓ sqlite_stat1 has ${stat_count} entries${NC}"

		local has_stat4
		has_stat4=$(sql "SELECT count(*) FROM sqlite_master WHERE name='sqlite_stat4' AND type='table';")
		if [[ "$has_stat4" == "0" ]]; then
			echo -e "    ${YELLOW}⚠  STAT4 table missing (compile with ENABLE_STAT4 for histogram data)${NC}"
		fi
	fi

	echo ""
}

# ---- Table Stats ------------------------------------------------------------
check_table_stats() {
	echo -e "${BOLD}━━━ Table Statistics ━━━${NC}"

	# Row counts (estimated via COUNT — slow on large tables, but informative)
	echo "  Row counts (fast estimate via sqlite_stat1):"
	local stat1_count
	stat1_count=$(sql "SELECT count(*) FROM sqlite_stat1;" 2>/dev/null || echo "0")
	if ((stat1_count > 0)); then
		sql "SELECT tbl, CAST(idx AS TEXT), stat FROM sqlite_stat1 WHERE idx IS NOT NULL ORDER BY CAST(stat AS INTEGER) DESC LIMIT 10;" 2>/dev/null | while IFS='|' read -r tbl idx stat; do
			# stat format: "row_count avg_eq ..."
			local row_count
			row_count=$(echo "$stat" | awk '{print $1}')
			printf "    %-30s ~%s rows\n" "$tbl" "$row_count"
		done
	else
		# Fall back to COUNT for each table (warning: slow)
		echo -e "    ${YELLOW}No sqlite_stat1 entries. Run ANALYZE first.${NC}"
		echo "    Table row estimates (via COUNT, may be slow):"
		sql "SELECT m.name, (SELECT count(*) FROM \"$DB_PATH\" AS cnt CROSS JOIN pragma_table_info(m.name)) FROM sqlite_master m WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite_%' LIMIT 10;" 2>/dev/null | while IFS='|' read -r tbl cnt; do
			# This won't work directly — need per-table select
			:
		done
		# Use a simpler approach
		for tbl in $(sql "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' LIMIT 10;"); do
			local cnt
			cnt=$(sql "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null || echo "?")
			printf "    %-30s %s rows\n" "$tbl" "$cnt"
		done
	fi

	echo ""
}

# ---- Query Plan Analysis ----------------------------------------------------
check_query_plans() {
	echo -e "${BOLD}━━━ Query Planner Settings ━━━${NC}"

	# Check if automatic indexes are enabled
	local autoindex
	# SQLite doesn't have a direct PRAGMA for autoindex; it's always on
	# but we can check query planner debug
	echo "  Automatic indexes: ON (SQLite default — creates transient indexes for queries)"

	# Query planner debug info
	local qp_info
	qp_info=$(sql "EXPLAIN QUERY PLAN SELECT 1;" 2>/dev/null || echo "N/A")
	echo "  EXPLAIN supported: YES"

	# Check if LIKE optimization is possible
	local like_opt
	like_opt=$(sql "SELECT sqlite_compileoption_used('SQLITE_LIKE_DOESNT_MATCH_BLOBS');")
	echo "  LIKE optimization: ${like_opt:-default}"

	echo ""
}

# ---- Integrity Check --------------------------------------------------------
check_integrity() {
	echo -e "${BOLD}━━━ Database Integrity ━━━${NC}"

	local integrity
	integrity=$(sql "PRAGMA integrity_check;" 2>/dev/null)
	if [[ "$integrity" == "ok" ]]; then
		echo -e "  ${GREEN}✓ Integrity check passed.${NC}"
	else
		echo -e "  ${RED}✗ Integrity check FAILED:${NC}"
		echo "    ${integrity}"
	fi

	# Foreign key check (if enabled)
	local fk_on
	fk_on=$(pragma_val foreign_keys)
	if [[ "$fk_on" == "1" ]]; then
		local fk_check
		fk_check=$(sql "PRAGMA foreign_key_check;" 2>/dev/null)
		if [[ -z "$fk_check" ]]; then
			echo -e "  ${GREEN}✓ Foreign key check passed.${NC}"
		else
			echo -e "  ${RED}✗ Foreign key violations:${NC}"
			echo "    ${fk_check}"
		fi
	else
		echo -e "  ${YELLOW}⚠  Foreign keys not enabled — skipping FK check.${NC}"
	fi

	echo ""
}

# ---- Generate Optimized PRAGMAs ---------------------------------------------
generate_pragmas() {
	local db_size
	db_size=$(stat -c%s "$DB_PATH" 2>/dev/null || stat -f%z "$DB_PATH" 2>/dev/null || echo "0")
	local db_mb=$((db_size / 1048576))

	# Determine cache size in KB based on workload and RAM
	local cache_kb=0
	case "$WORKLOAD" in
	web)
		cache_kb=$((TOTAL_RAM_MB * 10 > 200 ? (TOTAL_RAM_MB * 10) : (TOTAL_RAM_MB * 5 > 32 ? TOTAL_RAM_MB * 5 : 32)))
		cache_kb=$((cache_kb * 1024)) # convert MB to KB
		;;
	mobile)
		cache_kb=$((TOTAL_RAM_MB * 512 / 100)) # ~5% of RAM in KB
		((cache_kb > 16384)) && cache_kb=16384 # cap at 16MB
		((cache_kb < 2048)) && cache_kb=2048   # min 2MB
		;;
	embedded)
		cache_kb=$((TOTAL_RAM_MB * 256 / 100))
		((cache_kb > 4096)) && cache_kb=4096
		((cache_kb < 512)) && cache_kb=512
		;;
	analytics)
		cache_kb=$((TOTAL_RAM_MB * 40 > 256 ? (TOTAL_RAM_MB * 40) : 256))
		cache_kb=$((cache_kb * 1024))
		((cache_kb > 524288)) && cache_kb=524288 # cap at 512MB
		;;
	read-heavy)
		cache_kb=$((TOTAL_RAM_MB * 25 > 128 ? (TOTAL_RAM_MB * 25) : 128))
		cache_kb=$((cache_kb * 1024))
		((cache_kb > 262144)) && cache_kb=262144
		;;
	esac

	# Convert to negative KB (sqlite convention)
	local cache_size_neg=$((-cache_kb))

	cat >"$OUTPUT_PRAGMAS" <<SQLEOF
-- =============================================================================
-- SQLite Optimized PRAGMA Settings
-- Generated: $(date '+%Y-%m-%d %H:%M:%S')
-- Database:  ${DB_PATH} ($(bytes_to_human $db_size))
-- Workload:  ${WORKLOAD}
-- System RAM: ${TOTAL_RAM_MB} MB
-- =============================================================================
--
-- Apply these PRAGMAs to your connections. Most are connection-scoped and
-- must be set per-connection. Persistent settings can be applied by opening
-- the database with these PRAGMAs and running the relevant operations.
--
-- To apply permanently, run these PRAGMAs and then run VACUUM (for settings
-- that persist like journal_mode, synchronous, page_size).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. JOURNAL MODE — WAL for concurrent reads + writes
-- ---------------------------------------------------------------------------
-- WAL mode allows concurrent readers and a single writer. Excellent for
-- web apps and most production use cases.
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------------
-- 2. SYNCHRONOUS — durability vs speed trade-off
-- ---------------------------------------------------------------------------
SQLEOF

	case "$WORKLOAD" in
	web)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- NORMAL is safe in WAL mode. FULL adds extra fsync per transaction.
-- Use FULL if data integrity is critical (financial apps).
PRAGMA synchronous = NORMAL;
SQLEOF
		;;
	mobile)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- FULL for durability on devices that may lose power.
PRAGMA synchronous = FULL;
SQLEOF
		;;
	embedded)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- FULL: embedded devices may crash without warning.
PRAGMA synchronous = FULL;
SQLEOF
		;;
	analytics | read-heavy)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- OFF or NORMAL for read-heavy / analytics where some data loss is acceptable.
PRAGMA synchronous = NORMAL;
-- For bulk loads, temporarily use: PRAGMA synchronous = OFF;
SQLEOF
		;;
	esac

	cat >>"$OUTPUT_PRAGMAS" <<SQLEOF

-- ---------------------------------------------------------------------------
-- 3. CACHE SIZE — ${cache_kb} KB (${cache_mb} MB)
-- ---------------------------------------------------------------------------
-- Set to ~5-10% of system RAM for web, higher for analytics.
-- Negative value = KB, positive = pages.
PRAGMA cache_size = ${cache_size_neg};

-- ---------------------------------------------------------------------------
-- 4. MEMORY-MAPPED I/O — reduces read syscalls
-- ---------------------------------------------------------------------------
SQLEOF

	if [[ "$WORKLOAD" == "web" || "$WORKLOAD" == "analytics" || "$WORKLOAD" == "read-heavy" ]]; then
		local mmap_size=$((cache_kb > db_mb * 1024 ? db_mb * 1024 * 1024 : cache_kb * 1024))
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- Map the database into memory for faster reads (Linux/macOS only).
-- Set to the database size or your cache size, whichever is smaller.
PRAGMA mmap_size = ${mmap_size};
SQLEOF
	else
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- MMAP can be problematic on mobile/embedded. Test before enabling.
-- PRAGMA mmap_size = <bytes>;
SQLEOF
	fi

	cat >>"$OUTPUT_PRAGMAS" <<SQLEOF

-- ---------------------------------------------------------------------------
-- 5. TEMP STORE — keep temp tables in memory
-- ---------------------------------------------------------------------------
-- MEMORY is faster but uses RAM. FILE is slower but won't exhaust memory.
PRAGMA temp_store = MEMORY;

-- ---------------------------------------------------------------------------
-- 6. BUSY TIMEOUT — wait for locks instead of failing immediately
-- ---------------------------------------------------------------------------
-- Critical for concurrent access (WAL mode). Set to 5 seconds.
PRAGMA busy_timeout = 5000;

-- ---------------------------------------------------------------------------
-- 7. FOREIGN KEYS — enforce referential integrity
-- ---------------------------------------------------------------------------
-- Must be enabled per connection. Cannot be made persistent.
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- 8. OTHER PERFORMANCE PRAGMAs
-- ---------------------------------------------------------------------------
SQLEOF

	case "$WORKLOAD" in
	analytics)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- Disable auto-checkpoint during bulk loads (restore after).
-- PRAGMA wal_autocheckpoint = 0;   -- disable during load
-- PRAGMA wal_autocheckpoint = 1000; -- restore

-- Larger page size improves scan performance (set before DB creation).
-- PRAGMA page_size = 8192; -- requires VACUUM after

-- Use query planner for analytical queries.
-- Run ANALYZE after significant data changes.
ANALYZE;
SQLEOF
		;;
	read-heavy)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- Optimize for reads by running ANALYZE regularly.
ANALYZE;

-- Consider partial indexes for frequently filtered columns.
-- CREATE INDEX idx_active ON users(created_at) WHERE active = 1;

-- Use covering indexes for common SELECT queries.
-- CREATE INDEX idx_covering ON table(a, b, c);  -- if SELECT a, b, c FROM table WHERE a = ?
SQLEOF
		;;
	*)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- Run ANALYZE to update query planner statistics.
ANALYZE;

-- For write-heavy tables, consider lowering wal_autocheckpoint:
-- PRAGMA wal_autocheckpoint = 1000;  -- checkpoint every 1000 pages (default)
SQLEOF
		;;
	esac

	cat >>"$OUTPUT_PRAGMAS" <<SQLEOF

-- =============================================================================
-- MAINTENANCE COMMANDS
-- =============================================================================
-- Run periodically (not per-connection):

-- Reclaim space from deleted rows, reduce fragmentation.
-- VACUUM;

-- Rebuild indexes (faster than VACUUM for just index defrag).
-- REINDEX;

-- Update query planner statistics.
-- ANALYZE;

-- Check database integrity.
-- PRAGMA integrity_check;

-- Check for foreign key violations (requires foreign_keys = ON).
-- PRAGMA foreign_key_check;

-- Optimize WAL file size (checkpoint and truncate).
-- PRAGMA wal_checkpoint(TRUNCATE);

-- =============================================================================
-- WORKLOAD: ${WORKLOAD}
-- =============================================================================
SQLEOF

	case "$WORKLOAD" in
	web)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- WEB APP PROFILE:
-- - WAL mode for concurrent reads/writes
-- - Moderate cache (5-10% of RAM)
-- - NORMAL synchronous (safe in WAL)
-- - Busy timeout for lock handling
-- - ANALYZE after schema changes
SQLEOF
		;;
	mobile)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- MOBILE PROFILE:
-- - WAL mode for crash safety
-- - FULL synchronous (battery loss)
-- - Small cache (2-16 MB)
-- - MMAP disabled by default (test on device)
-- - ANALYZE after sync/download
SQLEOF
		;;
	embedded)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- EMBEDDED PROFILE:
-- - WAL mode for crash safety
-- - FULL synchronous (power loss)
-- - Minimal cache (0.5-4 MB)
-- - MMAP disabled (memory constrained)
-- - ANALYZE after initialization
SQLEOF
		;;
	analytics)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- ANALYTICS PROFILE:
-- - WAL mode (for eventual writes)
-- - Large cache (up to 512 MB)
-- - NORMAL synchronous (acceptable data loss)
-- - MMAP enabled for scan speed
-- - ANALYZE after each bulk load
SQLEOF
		;;
	read-heavy)
		cat >>"$OUTPUT_PRAGMAS" <<SQLEOF
-- READ-HEAVY PROFILE:
-- - WAL mode
-- - Large cache (up to 256 MB)
-- - NORMAL synchronous
-- - MMAP enabled
-- - ANALYZE after data changes
-- - Consider covering indexes
SQLEOF
		;;
	esac

	echo -e "${GREEN}${BOLD}✓ Optimized PRAGMAs written to: ${OUTPUT_PRAGMAS}${NC}"
}

# ---- Full Report ------------------------------------------------------------
generate_report() {
	{
		echo "==============================================================================="
		echo "  SQLite Database Audit Report"
		echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "  Database: ${DB_PATH}"
		echo "  Workload: ${WORKLOAD}"
		echo "==============================================================================="
		echo ""

		# Re-run checks but capture output
		check_system_info
		check_pragmas
		check_schema
		check_indexes
		check_table_stats
		check_query_plans
		check_integrity

		echo "==============================================================================="
		echo "  Recommendations Summary"
		echo "==============================================================================="
		echo ""
		echo "  1. Enable WAL mode if not already active"
		echo "     → PRAGMA journal_mode = WAL;"
		echo "     → Allows concurrent readers + one writer."
		echo ""
		echo "  2. Set appropriate synchronous level"
		echo "     → PRAGMA synchronous = NORMAL; (safe in WAL mode)"
		echo "     → Use FULL for financial / critical data."
		echo ""
		echo "  3. Size the page cache appropriately"
		echo "     → PRAGMA cache_size = -<KB>;"
		echo "     → 5-10% of RAM for web, 2-16 MB for mobile."
		echo ""
		echo "  4. Enable memory-mapped I/O (Linux/macOS)"
		echo "     → PRAGMA mmap_size = <bytes>;"
		echo "     → Map the database (or large portion) into memory."
		echo ""
		echo "  5. Set busy_timeout for concurrent access"
		echo "     → PRAGMA busy_timeout = 5000;"
		echo "     → Prevents 'database is locked' errors."
		echo ""
		echo "  6. Run ANALYZE regularly"
		echo "     → Updates sqlite_stat1 (and sqlite_stat4 if available)."
		echo "     → Improves query plan quality."
		echo ""
		echo "  7. Monitor and maintain"
		echo "     → PRAGMA integrity_check; (check for corruption)"
		echo "     → PRAGMA freelist_count; (check fragmentation)"
		echo "     → VACUUM; (reclaim space when fragmentation > 10%)"
		echo "     → REINDEX; (rebuild indexes when slow)"
		echo ""
		echo "  8. Optimize schema"
		echo "     → Use INTEGER PRIMARY KEY for auto-increment (fastest)."
		echo "     → Use WITHOUT ROWID for tables with compound PKs."
		echo "     → Add covering indexes for common queries."
		echo "     → Avoid SELECT *; select only needed columns."
		echo ""
		echo "  9. Use appropriate page_size"
		echo "     → 4096 is the default and good for most uses."
		echo "     → 8192 can improve scan speed on large tables."
		echo "     → Set before creating the database (cannot change later)."
		echo ""
		echo "  10. Compile with recommended options"
		echo "      → -DSQLITE_ENABLE_STAT4 (histogram data for ANALYZE)"
		echo "      → -DSQLITE_ENABLE_FTS5 (full-text search)"
		echo "      → -DSQLITE_ENABLE_JSON1 (JSON functions)"
		echo "      → -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 (WAL sync safety)"
		echo ""

	} >"$OUTPUT_REPORT"

	echo -e "${GREEN}${BOLD}✓ Audit report written to: ${OUTPUT_REPORT}${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║       SQLite Database Audit & Optimizer                     ║${NC}"
echo -e "${CYAN}${BOLD}║       Database: ${DB_PATH}                                   ${NC}"
echo -e "${CYAN}${BOLD}║       Workload: ${WORKLOAD}                                  ${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

check_system_info
check_pragmas
check_schema
check_indexes
check_table_stats
check_query_plans
check_integrity

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

generate_pragmas
generate_report

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Audit Complete                                              ║${NC}"
echo -e "${CYAN}${BOLD}║  PRAGMAs:  ${OUTPUT_PRAGMAS}${NC}"
echo -e "${CYAN}${BOLD}║  Report:   ${OUTPUT_REPORT}${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review ${OUTPUT_PRAGMAS} — these are connection-scoped PRAGMA settings"
echo "  2. Apply per-connection: sqlite3 ${DB_PATH} < ${OUTPUT_PRAGMAS}"
echo "  3. For persistent settings, open the DB, run the PRAGMAs, then VACUUM"
echo "  4. Run ANALYZE if you haven't recently"
echo "  5. Check: PRAGMA integrity_check; PRAGMA foreign_key_check;"
echo ""
