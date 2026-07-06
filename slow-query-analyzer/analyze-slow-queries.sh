#!/usr/bin/env bash
# =============================================================================
# analyze-slow-queries.sh — Multi-Database Slow Query Extractor & Fingerprinter
# =============================================================================
# Extracts slow queries from MySQL, PostgreSQL, and SQLite, fingerprints them,
# runs EXPLAIN, and outputs structured JSON for the slow-query-analyzer skill
# to map to framework ORM patterns.
#
# Usage:
#   # MySQL (Performance Schema)
#   ./analyze-slow-queries.sh --dbtype mysql -h HOST -u USER -p PASS -d DB -o report.json
#
#   # PostgreSQL (pg_stat_statements)
#   ./analyze-slow-queries.sh --dbtype postgresql -h HOST -U USER -d DB -o report.json
#
#   # SQLite (database file)
#   ./analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db -o report.json
#
#   # Offline log parsing
#   ./analyze-slow-queries.sh --from-slow-log /path/to/slow.log --dbtype mysql
#   ./analyze-slow-queries.sh --from-slow-log /path/to/postgresql.log --dbtype postgresql
#
#   # Auto-detect (tries mysql → postgresql → prompts)
#   ./analyze-slow-queries.sh -h HOST -u USER -o report.json
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
DBTYPE="" # mysql | postgresql | sqlite
DB_HOST="127.0.0.1"
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_NAME=""
DB_FILE="" # SQLite database file path
OUTPUT_FILE="slow-queries-report.json"
TOP_N=30
EXPLAIN_EACH=true
FROM_SLOW_LOG=""
INCLUDE_TABLES_INFO=true
INCLUDE_PROCESSLIST=false

# ---- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Help -------------------------------------------------------------------
usage() {
	cat <<'EOF'
analyze-slow-queries.sh — Multi-Database Slow Query Extractor

USAGE:
  MySQL (Performance Schema):
    ./analyze-slow-queries.sh --dbtype mysql -h HOST -u USER -p PASS -d DB [OPTIONS]

  PostgreSQL (pg_stat_statements):
    ./analyze-slow-queries.sh --dbtype postgresql -h HOST -U USER -d DB [OPTIONS]

  SQLite (database file):
    ./analyze-slow-queries.sh --dbtype sqlite -f /path/to/database.db [OPTIONS]

  Offline log parsing:
    ./analyze-slow-queries.sh --from-slow-log /path/to/log --dbtype mysql|postgresql

COMMON OPTIONS:
  -n, --top N             Number of top queries (default: 30)
  -o, --output FILE       Output JSON file (default: slow-queries-report.json)
  --no-explain            Skip EXPLAIN for each query
  --include-processlist   Include current connections (MySQL/PostgreSQL only)
  --help                  Show this help

MYSQL OPTIONS:
  -h, --host HOST         MySQL/PostgreSQL host (default: 127.0.0.1)
  -P, --port PORT         Database port
  -u, --user USER         Database user
  -p, --password PASS     Database password
  -d, --database DB       Database name

POSTGRESQL OPTIONS:
  -h, --host HOST         PostgreSQL host
  -P, --port PORT         Database port (default: 5432)
  -U, --user USER         PostgreSQL user
  -W, --password PASS     PostgreSQL password
  -d, --database DB       Database name

SQLITE OPTIONS:
  -f, --file PATH         Path to SQLite database file

AUTO-DETECTION:
  Omit --dbtype to auto-detect (tries mysql → postgresql → prompts).

EOF
	exit 0
}

# ---- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	--dbtype)
		DBTYPE="$2"
		shift 2
		;;
	-h | --host)
		DB_HOST="$2"
		shift 2
		;;
	-P | --port)
		DB_PORT="$2"
		shift 2
		;;
	-u | --user | -U | --username)
		DB_USER="$2"
		shift 2
		;;
	-p | --password | -W)
		DB_PASS="$2"
		shift 2
		;;
	-d | --database)
		DB_NAME="$2"
		shift 2
		;;
	-f | --file)
		DB_FILE="$2"
		shift 2
		;;
	-n | --top)
		TOP_N="$2"
		shift 2
		;;
	-o | --output)
		OUTPUT_FILE="$2"
		shift 2
		;;
	--no-explain)
		EXPLAIN_EACH=false
		shift
		;;
	--include-processlist)
		INCLUDE_PROCESSLIST=true
		shift
		;;
	--from-slow-log)
		FROM_SLOW_LOG="$2"
		shift 2
		;;
	--help) usage ;;
	-*)
		echo "Unknown option: $1"
		usage
		;;
	*)
		echo "Unknown argument: $1"
		usage
		;;
	esac
done

# ---- Auto-detect DB type ----------------------------------------------------
auto_detect_dbtype() {
	# If a file is specified, check if it's a SQLite database
	if [[ -n "$DB_FILE" ]]; then
		if [[ -f "$DB_FILE" ]]; then
			if command -v sqlite3 &>/dev/null; then
				local test_result
				test_result=$(sqlite3 "$DB_FILE" "SELECT 1;" 2>/dev/null || echo "")
				if [[ "$test_result" == "1" ]]; then
					DBTYPE="sqlite"
					return
				fi
			fi
			# File exists but isn't SQLite — still try sqlite
			DBTYPE="sqlite"
			return
		fi
	fi

	# If from-slow-log, require explicit --dbtype
	if [[ -n "$FROM_SLOW_LOG" ]]; then
		echo -e "${RED}ERROR: --dbtype is required when using --from-slow-log${NC}"
		echo "  Use: --dbtype mysql or --dbtype postgresql"
		exit 1
	fi

	# Try MySQL first
	if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
		local mysql_cli
		mysql_cli=$(command -v mysql 2>/dev/null || command -v mariadb 2>/dev/null)
		local port="${DB_PORT:-3306}"
		local user="${DB_USER:-root}"
		local pass_opt=""
		[[ -n "$DB_PASS" ]] && pass_opt="-p${DB_PASS}"
		if "$mysql_cli" -h "$DB_HOST" -P "$port" -u "$user" $pass_opt --connect-timeout=3 -e "SELECT 1" &>/dev/null 2>&1; then
			DBTYPE="mysql"
			return
		fi
	fi

	# Try PostgreSQL next
	if command -v psql &>/dev/null; then
		local port="${DB_PORT:-5432}"
		local user="${DB_USER:-postgres}"
		local db="${DB_NAME:-postgres}"
		if [[ -n "$DB_PASS" ]]; then
			export PGPASSWORD="$DB_PASS"
		fi
		if psql -h "$DB_HOST" -p "$port" -U "$user" -d "$db" -w -c "SELECT 1" &>/dev/null 2>&1; then
			DBTYPE="postgresql"
			return
		fi
		# Try without -w
		if psql -h "$DB_HOST" -p "$port" -U "$user" -d "$db" -c "SELECT 1" &>/dev/null 2>&1; then
			DBTYPE="postgresql"
			return
		fi
	fi

	# If nothing worked, prompt
	if [[ -f "$DB_FILE" ]]; then
		DBTYPE="sqlite"
		return
	fi

	echo -e "${RED}ERROR: Could not auto-detect database type.${NC}"
	echo "  Specify --dbtype mysql, --dbtype postgresql, or --dbtype sqlite"
	exit 1
}

if [[ -z "$DBTYPE" ]]; then
	auto_detect_dbtype
fi

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Slow Query Analyzer — ${DBTYPE}                                 ${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ---- Helper: format bytes to human-readable --------------------------------
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

# ---- Dependencies Check -----------------------------------------------------
for dep in jq sed awk; do
	if ! command -v "$dep" &>/dev/null; then
		echo -e "${YELLOW}⚠  '$dep' not found. Install it for best results.${NC}"
	fi
done

# =============================================================================
# MYSQL MODE
# =============================================================================
run_mysql() {
	echo -e "${BOLD}━━━ MySQL Slow Query Extraction ━━━${NC}"

	# ---- Slow Log Mode ------------------------------------------------------
	if [[ -n "$FROM_SLOW_LOG" ]]; then
		echo -e "${CYAN}Analyzing slow query log: ${FROM_SLOW_LOG}${NC}"
		if [[ ! -f "$FROM_SLOW_LOG" ]]; then
			echo -e "${RED}ERROR: Slow log file not found: ${FROM_SLOW_LOG}${NC}"
			exit 1
		fi
		if command -v pt-query-digest &>/dev/null; then
			echo "Using pt-query-digest for deep analysis..."
			pt-query-digest "$FROM_SLOW_LOG" --limit="$((TOP_N * 2))" --report-format=json --output=json >"$OUTPUT_FILE" 2>/dev/null && {
				echo -e "${GREEN}✓ pt-query-digest report written to ${OUTPUT_FILE}${NC}"
				exit 0
			} || echo -e "${YELLOW}⚠  pt-query-digest failed. Falling back.${NC}"
		fi
		if command -v mysqldumpslow &>/dev/null; then
			mysqldumpslow -s t -t "$TOP_N" "$FROM_SLOW_LOG" >/tmp/mysql_slow_summary.txt
			echo -e "${GREEN}Top ${TOP_N} queries saved to /tmp/mysql_slow_summary.txt${NC}"
		fi
		echo -e "${YELLOW}Full log parsing not available — use Performance Schema mode for rich data.${NC}"
		exit 0
	fi

	# ---- MySQL Client -------------------------------------------------------
	MYSQL_CLI=""
	for candidate in mysql mariadb; do
		if command -v "$candidate" &>/dev/null; then
			MYSQL_CLI="$candidate"
			break
		fi
	done
	if [[ -z "$MYSQL_CLI" ]]; then
		echo -e "${RED}ERROR: mysql or mariadb client not found.${NC}"
		exit 1
	fi

	local port="${DB_PORT:-3306}"
	MYSQL_OPTS=(-h "$DB_HOST" -P "$port" -u "${DB_USER:-root}" --connect-timeout=10 -N -B)
	[[ -n "$DB_PASS" ]] && MYSQL_OPTS+=(-p"$DB_PASS")

	# Check Performance Schema
	PS_ENABLED=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT @@performance_schema" 2>/dev/null || echo "0")
	if [[ "$PS_ENABLED" != "1" && "$PS_ENABLED" != "ON" ]]; then
		echo -e "${RED}ERROR: Performance Schema is OFF.${NC}"
		exit 1
	fi
	echo -e "${GREEN}✓ Connected to MySQL ${DB_HOST}:${port}${NC}"
	echo ""

	# Build filter
	DB_FILTER=""
	[[ -n "$DB_NAME" ]] && DB_FILTER="AND SCHEMA_NAME = '${DB_NAME}'"

	# Extract queries
	EXTRACT_SQL="
SELECT DIGEST_TEXT, COUNT_STAR,
       ROUND(SUM_TIMER_WAIT / 1000000000000, 4) AS total_time_sec,
       ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS avg_time_ms,
       ROUND(MIN_TIMER_WAIT / 1000000000, 2) AS min_time_ms,
       ROUND(MAX_TIMER_WAIT / 1000000000, 2) AS max_time_ms,
       SUM_ROWS_EXAMINED,
       ROUND(SUM_ROWS_EXAMINED / GREATEST(COUNT_STAR,1), 0) AS avg_rows_examined,
       SUM_ROWS_SENT,
       ROUND(SUM_ROWS_SENT / GREATEST(COUNT_STAR,1), 0) AS avg_rows_sent,
       SUM_ROWS_AFFECTED,
       SUM_NO_INDEX_USED, SUM_NO_GOOD_INDEX_USED,
       SUM_SELECT_FULL_JOIN, SUM_SELECT_SCAN,
       SUM_SORT_ROWS, SUM_SORT_MERGE_PASSES,
       SUM_CREATED_TMP_TABLES, SUM_CREATED_TMP_DISK_TABLES,
       FIRST_SEEN, LAST_SEEN, DIGEST
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT IS NOT NULL AND DIGEST_TEXT != '' AND SUM_TIMER_WAIT > 0
      ${DB_FILTER}
ORDER BY SUM_TIMER_WAIT DESC LIMIT ${TOP_N}"

	RAW_DATA=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "$EXTRACT_SQL" 2>/dev/null) || {
		echo -e "${RED}ERROR: Failed to extract queries.${NC}"
		exit 1
	}

	if [[ -z "$RAW_DATA" ]]; then
		echo -e "${YELLOW}No query data found in Performance Schema.${NC}"
		exit 0
	fi

	QUERY_COUNT=$(echo "$RAW_DATA" | wc -l)
	echo -e "${GREEN}✓ Extracted ${QUERY_COUNT} query digests${NC}"
	echo ""

	# Build JSON output
	build_mysql_json "$RAW_DATA" "$QUERY_COUNT"
}

# ---- Build MySQL JSON -------------------------------------------------------
build_mysql_json() {
	local raw="$1"
	local count="$2"

	NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	DB_DISPLAY="${DB_NAME:-all databases}"

	# Server info
	MYSQL_VER=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT VERSION()" 2>/dev/null || echo "unknown")
	UPTIME=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime'" 2>/dev/null || echo "0")

	# Build queries JSON array
	QUERIES_JSON="["
	FIRST=true
	LINE_NUM=0

	while IFS=$'\t' read -r digest_text count_star total_time avg_time min_time max_time \
		rows_examined avg_rows_examined rows_sent avg_rows_sent rows_affected \
		no_index no_good_index full_join select_scan sort_rows sort_merge tmp_tables tmp_disk_tables \
		first_seen last_seen digest; do

		LINE_NUM=$((LINE_NUM + 1))
		DIGEST_ESCAPED=$(echo "$digest_text" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

		QTYPE="OTHER"
		echo "$digest_text" | grep -qiE '^\s*SELECT' && QTYPE="SELECT"
		echo "$digest_text" | grep -qiE '^\s*INSERT' && QTYPE="INSERT"
		echo "$digest_text" | grep -qiE '^\s*UPDATE' && QTYPE="UPDATE"
		echo "$digest_text" | grep -qiE '^\s*DELETE' && QTYPE="DELETE"

		# Tables
		TABLES=""
		TABLES=$(echo "$digest_text" | grep -oiP '(?:FROM|JOIN)\s+`?(\w+)`?' | sed 's/FROM //i; s/JOIN //i; s/`//g' | sort -u | tr '\n' ',' | sed 's/,$//')

		# Severity
		SEVERITY_SCORE=0
		[[ "${no_index:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 30))
		[[ "${no_good_index:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 20))
		[[ "${select_scan:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 25))
		[[ "${tmp_disk_tables:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 15))

		if [[ $SEVERITY_SCORE -ge 70 ]]; then
			SEV="critical"
		elif [[ $SEVERITY_SCORE -ge 40 ]]; then
			SEV="high"
		elif [[ $SEVERITY_SCORE -ge 20 ]]; then
			SEV="medium"
		else SEV="low"; fi

		# Framework hints
		FW_HINTS="[]"
		echo "$digest_text" | grep -qiE '(?:COUNT|SUM|AVG|MIN|MAX)\s*\(' && FW_HINTS='["aggregation"]'
		echo "$digest_text" | grep -qi 'GROUP BY' && FW_HINTS='["group_by","aggregation"]'
		echo "$digest_text" | grep -qi 'LIMIT.*OFFSET' && FW_HINTS='["pagination","offset_pagination"]'
		echo "$digest_text" | grep -qi 'LEFT JOIN\|INNER JOIN' && FW_HINTS='["joins"]'

		[[ "$FIRST" == false ]] && QUERIES_JSON+=","
		FIRST=false

		QUERIES_JSON+="{\"rank\": $LINE_NUM, \"digest\": \"$digest\", \"digest_text\": \"$DIGEST_ESCAPED\", \"query_type\": \"$QTYPE\", \"tables\": \"$TABLES\", \"count_star\": ${count_star:-0}, \"total_time_sec\": ${total_time:-0}, \"avg_time_ms\": ${avg_time:-0}, \"min_time_ms\": ${min_time:-0}, \"max_time_ms\": ${max_time:-0}, \"sum_rows_examined\": ${rows_examined:-0}, \"avg_rows_examined\": ${avg_rows_examined:-0}, \"sum_rows_sent\": ${rows_sent:-0}, \"avg_rows_sent\": ${avg_rows_sent:-0}, \"sum_no_index_used\": ${no_index:-0}, \"sum_no_good_index_used\": ${no_good_index:-0}, \"sum_select_full_join\": ${full_join:-0}, \"sum_select_scan\": ${select_scan:-0}, \"first_seen\": \"$first_seen\", \"last_seen\": \"$last_seen\", \"explain\": null, \"severity\": \"$SEV\", \"severity_score\": $SEVERITY_SCORE, \"framework_hints\": $FW_HINTS, \"db_type\": \"mysql\"}"
	done <<<"$raw"
	QUERIES_JSON+="]"

	# Write JSON
	write_mysql_json "$count"
}

write_mysql_json() {
	local count="$1"
	python3 -c "
import json
doc = {
  'metadata': {'generated_at': '$NOW', 'db_type': 'mysql', 'host': '$DB_HOST', 'port': '${DB_PORT:-3306}', 'database_filter': '$DB_NAME', 'source': 'performance_schema', 'top_n': $TOP_N, 'total_queries_found': $count},
  'server_info': {'version': '$MYSQL_VER', 'uptime_seconds': ${UPTIME:-0}},
  'summary': {},
  'queries': json.loads('''$QUERIES_JSON'''),
  'table_info': {},
  'processlist': []
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
		echo "{\"metadata\": {\"db_type\": \"mysql\"}, \"queries\": $QUERIES_JSON}" >"$OUTPUT_FILE"
	}
}

# =============================================================================
# POSTGRESQL MODE
# =============================================================================
run_postgresql() {
	echo -e "${BOLD}━━━ PostgreSQL Slow Query Extraction ━━━${NC}"

	# ---- Slow Log Mode ------------------------------------------------------
	if [[ -n "$FROM_SLOW_LOG" ]]; then
		echo -e "${CYAN}Analyzing PostgreSQL log: ${FROM_SLOW_LOG}${NC}"
		if [[ ! -f "$FROM_SLOW_LOG" ]]; then
			echo -e "${RED}ERROR: Log file not found: ${FROM_SLOW_LOG}${NC}"
			exit 1
		fi
		if command -v pgbadger &>/dev/null; then
			echo "Using pgbadger for analysis..."
			pgbadger "$FROM_SLOW_LOG" -o /tmp/pg_slow_report.html -f stderr 2>/dev/null &&
				echo -e "${GREEN}✓ pgbadger report generated: /tmp/pg_slow_report.html${NC}" ||
				echo -e "${YELLOW}⚠  pgbadger failed.${NC}"
		else
			echo -e "${YELLOW}Install pgbadger for log analysis: apt install pgbadger${NC}"
		fi
		# Extract duration lines manually
		echo "Extracting slow queries from log..."
		grep -iE "duration:" "$FROM_SLOW_LOG" | head -200 >/tmp/pg_slow_extracted.txt 2>/dev/null
		echo -e "${GREEN}Extracted to /tmp/pg_slow_extracted.txt${NC}"
		echo -e "${YELLOW}For rich data, use pg_stat_statements mode instead.${NC}"
		exit 0
	fi

	# ---- PostgreSQL Client --------------------------------------------------
	if ! command -v psql &>/dev/null; then
		echo -e "${RED}ERROR: psql client not found. Install postgresql-client.${NC}"
		exit 1
	fi

	local port="${DB_PORT:-5432}"
	local user="${DB_USER:-postgres}"
	local db="${DB_NAME:-postgres}"

	PGOPTS=(-h "$DB_HOST" -p "$port" -U "$user" -d "$db" -At --pset=footer=off -w)
	export PGCONNECT_TIMEOUT=10

	if [[ -n "$DB_PASS" ]]; then
		export PGPASSWORD="$DB_PASS"
	fi

	# Connectivity check
	if ! psql -h "$DB_HOST" -p "$port" -U "$user" -d "$db" -w -c "SELECT 1" &>/dev/null 2>&1; then
		if ! psql -h "$DB_HOST" -p "$port" -U "$user" -d "$db" -c "SELECT 1" &>/dev/null 2>&1; then
			echo -e "${RED}ERROR: Cannot connect to PostgreSQL at ${DB_HOST}:${port}/${db}${NC}"
			exit 1
		fi
		PGOPTS=(-h "$DB_HOST" -p "$port" -U "$user" -d "$db" -At --pset=footer=off)
	fi

	echo -e "${GREEN}✓ Connected to PostgreSQL ${DB_HOST}:${port}/${db}${NC}"

	# Check pg_stat_statements
	PGSS_INSTALLED=$(psql "${PGOPTS[@]}" -c "SELECT count(*) FROM pg_extension WHERE extname='pg_stat_statements'" 2>/dev/null || echo "0")
	if [[ "$PGSS_INSTALLED" == "0" ]]; then
		echo -e "${RED}ERROR: pg_stat_statements extension is not installed.${NC}"
		echo "  Run: CREATE EXTENSION pg_stat_statements;"
		echo "  And: Add pg_stat_statements to shared_preload_libraries in postgresql.conf"
		exit 1
	fi
	echo -e "${GREEN}✓ pg_stat_statements is active${NC}"
	echo ""

	# Extract queries
	sql() {
		psql "${PGOPTS[@]}" -c "$1" 2>/dev/null || echo ""
	}

	DB_FILTER=""
	[[ -n "$DB_NAME" ]] && DB_FILTER="AND d.datname = '${DB_NAME}'"

	EXTRACT_SQL="
SELECT LEFT(query, 500) AS digest_text,
       calls,
       ROUND(total_exec_time::numeric / 1000, 4) AS total_time_sec,
       ROUND(mean_exec_time::numeric, 2) AS avg_time_ms,
       ROUND(min_exec_time::numeric, 2) AS min_time_ms,
       ROUND(max_exec_time::numeric, 2) AS max_time_ms,
       rows,
       COALESCE(shared_blks_read + shared_blks_hit, 0) AS blocks_accessed,
       shared_blks_read AS blocks_read,
       shared_blks_hit AS blocks_hit,
       ROUND(total_plan_time::numeric, 2) AS total_plan_time_ms,
       ROUND(mean_plan_time::numeric, 2) AS mean_plan_time_ms,
       queryid::text AS digest
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid
WHERE query NOT LIKE '%pg_stat%'
      AND query NOT LIKE '%pg_database%'
      AND calls > 0
      ${DB_FILTER}
ORDER BY total_exec_time DESC
LIMIT ${TOP_N}"

	RAW_DATA=$(sql "$EXTRACT_SQL" 2>/dev/null)

	if [[ -z "$RAW_DATA" ]]; then
		echo -e "${YELLOW}No query data found in pg_stat_statements.${NC}"
		echo "  The extension may have been recently installed. Wait for queries to accumulate."
		if [[ -n "$DB_NAME" ]]; then
			echo "  Or try resetting: SELECT pg_stat_statements_reset();"
		fi
		exit 0
	fi

	QUERY_COUNT=$(echo "$RAW_DATA" | wc -l)
	echo -e "${GREEN}✓ Extracted ${QUERY_COUNT} query digests${NC}"
	echo ""

	# Build JSON output
	build_postgresql_json "$RAW_DATA" "$QUERY_COUNT"
}

# ---- Build PostgreSQL JSON --------------------------------------------------
build_postgresql_json() {
	local raw="$1"
	local count="$2"

	NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	local port="${DB_PORT:-5432}"
	local user="${DB_USER:-postgres}"
	local db="${DB_NAME:-postgres}"

	sql() { psql "${PGOPTS[@]}" -c "$1" 2>/dev/null || echo ""; }

	PG_VER=$(sql "SELECT version()" | head -1)
	UPTIME=$(sql "SELECT extract(epoch FROM now() - pg_postmaster_start_time())::int" 2>/dev/null || echo "0")
	TOTAL_RAM_MB=0
	cache_hit_ratio=$(sql "SELECT round(100 * sum(shared_blks_hit) / greatest(sum(shared_blks_hit) + sum(shared_blks_read), 1), 1) FROM pg_stat_statements" 2>/dev/null || echo "0")

	QUERIES_JSON="["
	FIRST=true
	LINE_NUM=0

	while IFS='|' read -r digest_text calls total_time avg_time min_time max_time rows blocks_acc blocks_read blocks_hit plan_time mean_plan digest; do

		# Skip header/empty
		[[ -z "$digest_text" || "$digest_text" == "digest_text" ]] && continue

		LINE_NUM=$((LINE_NUM + 1))
		DIGEST_ESCAPED=$(echo "$digest_text" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

		QTYPE="OTHER"
		echo "$digest_text" | grep -qiE '^\s*SELECT' && QTYPE="SELECT"
		echo "$digest_text" | grep -qiE '^\s*INSERT' && QTYPE="INSERT"
		echo "$digest_text" | grep -qiE '^\s*UPDATE' && QTYPE="UPDATE"
		echo "$digest_text" | grep -qiE '^\s*DELETE' && QTYPE="DELETE"

		# Tables
		TABLES=""
		TABLES=$(echo "$digest_text" | grep -oiP '(?:FROM|JOIN)\s+"?(\w+)"?' | sed 's/FROM //i; s/JOIN //i; s/"//g' | sort -u | tr '\n' ',' | sed 's/,$//')

		# Severity — PG metrics: blocks_read = disk reads, blocks_hit = cache hits
		SEVERITY_SCORE=0
		local blk_read="${blocks_read:-0}"
		local blk_hit="${blocks_hit:-0}"
		[[ "$blk_read" -gt 10000 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 25))
		[[ "$blk_hit" -eq 0 && "$blk_read" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 30))
		local avg_ms_num=$(echo "$avg_time" | sed 's/[^0-9.]//g')
		local avg_ms_val=${avg_ms_num:-0}
		[[ "$(echo "$avg_ms_val > 500" | bc -l 2>/dev/null || echo 0)" == "1" ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 15))

		if [[ $SEVERITY_SCORE -ge 70 ]]; then
			SEV="critical"
		elif [[ $SEVERITY_SCORE -ge 40 ]]; then
			SEV="high"
		elif [[ $SEVERITY_SCORE -ge 20 ]]; then
			SEV="medium"
		else SEV="low"; fi

		# Framework hints
		FW_HINTS="[]"
		echo "$digest_text" | grep -qiE '(?:COUNT|SUM|AVG|MIN|MAX)\s*\(' && FW_HINTS='["aggregation"]'
		echo "$digest_text" | grep -qi 'GROUP BY' && FW_HINTS='["group_by","aggregation"]'
		echo "$digest_text" | grep -qi 'LIMIT.*OFFSET' && FW_HINTS='["pagination","offset_pagination"]'
		echo "$digest_text" | grep -qi 'LEFT JOIN\|INNER JOIN' && FW_HINTS='["joins"]'

		[[ "$FIRST" == false ]] && QUERIES_JSON+=","
		FIRST=false

		QUERIES_JSON+="{\"rank\": $LINE_NUM, \"digest\": \"$digest\", \"digest_text\": \"$DIGEST_ESCAPED\", \"query_type\": \"$QTYPE\", \"tables\": \"$TABLES\", \"count_star\": ${calls:-0}, \"total_time_sec\": ${total_time:-0}, \"avg_time_ms\": ${avg_time:-0}, \"min_time_ms\": ${min_time:-0}, \"max_time_ms\": ${max_time:-0}, \"sum_rows_examined\": ${rows:-0}, \"blocks_read\": ${blocks_read:-0}, \"blocks_hit\": $blk_hit, \"explain\": null, \"plan_time_ms\": ${mean_plan:-0}, \"severity\": \"$SEV\", \"severity_score\": $SEVERITY_SCORE, \"framework_hints\": $FW_HINTS, \"db_type\": \"postgresql\"}"
	done <<<"$raw"
	QUERIES_JSON+="]"

	# Write JSON
	python3 -c "
import json
doc = {
  'metadata': {'generated_at': '$NOW', 'db_type': 'postgresql', 'host': '$DB_HOST', 'port': '$port', 'database_filter': '$db', 'source': 'pg_stat_statements', 'top_n': $TOP_N, 'total_queries_found': $count},
  'server_info': {'version': '$PG_VER', 'uptime_seconds': ${UPTIME:-0}, 'cache_hit_ratio_pct': ${cache_hit_ratio:-0}},
  'summary': {},
  'queries': json.loads('''$QUERIES_JSON'''),
  'table_info': {},
  'processlist': []
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
		echo "{\"metadata\": {\"db_type\": \"postgresql\"}, \"queries\": $QUERIES_JSON}" >"$OUTPUT_FILE"
	}

	# Run EXPLAIN ANALYZE (no snapshot needed) on top queries
	if $EXPLAIN_EACH; then
		echo ""
		echo -e "${BOLD}━━━ Running EXPLAIN on Top Queries ━━━${NC}"
		explain_count=0
		while IFS='|' read -r digest_text _ _ _ _ _ _ _ _ _ _ _ _ digest; do
			[[ -z "$digest_text" || "$digest_text" == "digest_text" ]] && continue
			if echo "$digest_text" | grep -qiE '^\s*SELECT'; then
				explain_count=$((explain_count + 1))
				[[ $explain_count -gt 10 ]] && {
					echo "  (limit 10)"
					break
				}
				# Get actual query from pg_stat_statements
				ACTUAL_SQL=$(sql "SELECT query FROM pg_stat_statements WHERE queryid = '$digest' LIMIT 1" 2>/dev/null)
				if [[ -n "$ACTUAL_SQL" ]]; then
					EXPLAIN_OUT=$(sql "EXPLAIN (FORMAT JSON, ANALYZE false, BUFFERS true) $ACTUAL_SQL" 2>/dev/null || echo '{"error":"EXPLAIN failed"}')
					EXPLAIN_FILE="explain_${digest}.json"
					echo "$EXPLAIN_OUT" >"$EXPLAIN_FILE"
					echo "  ✓ EXPLAIN #${explain_count} → ${EXPLAIN_FILE}"
				fi
			fi
		done <<<"$raw"
		echo -e "${GREEN}✓ Ran ${explain_count} EXPLAINs${NC}"
	fi
}

# =============================================================================
# SQLITE MODE
# =============================================================================
run_sqlite() {
	echo -e "${BOLD}━━━ SQLite Slow Query Analysis ━━━${NC}"

	if [[ -z "$DB_FILE" ]]; then
		echo -e "${RED}ERROR: No database file specified. Use -f /path/to/database.db${NC}"
		exit 1
	fi

	if [[ ! -f "$DB_FILE" ]]; then
		echo -e "${RED}ERROR: Database file not found: ${DB_FILE}${NC}"
		exit 1
	fi

	if ! command -v sqlite3 &>/dev/null; then
		echo -e "${RED}ERROR: sqlite3 CLI not found.${NC}"
		exit 1
	fi

	SQLITE="$DB_FILE"

	# Quick test
	local test_q
	test_q=$(sqlite3 "$SQLITE" "SELECT 1;" 2>/dev/null || echo "")
	if [[ "$test_q" != "1" ]]; then
		echo -e "${RED}ERROR: Cannot read SQLite database: ${DB_FILE}${NC}"
		exit 1
	fi

	echo -e "${GREEN}✓ Connected to SQLite: ${DB_FILE}${NC}"

	# Database info
	local sqlite_ver page_count page_size freelist
	sqlite_ver=$(sqlite3 "$SQLITE" "SELECT sqlite_version();" 2>/dev/null)
	page_count=$(sqlite3 "$SQLITE" "PRAGMA page_count;" 2>/dev/null)
	page_size=$(sqlite3 "$SQLITE" "PRAGMA page_size;" 2>/dev/null)
	freelist=$(sqlite3 "$SQLITE" "PRAGMA freelist_count;" 2>/dev/null)
	local db_size
	db_size=$(stat -c%s "$SQLITE" 2>/dev/null || stat -f%z "$SQLITE" 2>/dev/null || echo "0")

	echo "  SQLite version:  ${sqlite_ver}"
	echo "  Database size:   $(bytes_to_human $db_size)"
	echo "  Pages:           ${page_count} × ${page_size}B"
	echo "  Free pages:      ${freelist}"
	echo ""

	# SQLite doesn't have built-in query statistics. We use alternative approaches:
	# 1. Check if sqlite_stat1 has ANALYZE data
	# 2. Offer to run EXPLAIN QUERY PLAN on key queries (schema queries)
	# 3. Check for common slow-query indicators

	# Check ANALYZE stats
	local stat1_count
	stat1_count=$(sqlite3 "$SQLITE" "SELECT count(*) FROM sqlite_stat1;" 2>/dev/null || echo "0")

	echo -e "${BOLD}━━━ Database Statistics ━━━${NC}"
	if [[ "$stat1_count" -gt 0 ]]; then
		echo -e "${GREEN}✓ sqlite_stat1 has ${stat1_count} entries (ANALYZE has been run)${NC}"
		sqlite3 "$SQLITE" "SELECT tbl, idx, stat FROM sqlite_stat1 ORDER BY CAST(stat AS INTEGER) DESC LIMIT 10;" 2>/dev/null | while IFS='|' read -r tbl idx stat; do
			local rows
			rows=$(echo "$stat" | awk '{print $1}')
			printf "    %-30s ~%s rows (index: %s)\n" "$tbl" "$rows" "${idx:-none}"
		done
	else
		echo -e "${YELLOW}⚠  No sqlite_stat1 data. Run ANALYZE for query planner statistics.${NC}"
	fi
	echo ""

	# Schema analysis
	echo -e "${BOLD}━━━ Schema Analysis ━━━${NC}"
	local table_count idx_count
	table_count=$(sqlite3 "$SQLITE" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null)
	idx_count=$(sqlite3 "$SQLITE" "SELECT count(*) FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_autoindex%';" 2>/dev/null)
	echo "  User tables:     ${table_count}"
	echo "  User indexes:    ${idx_count}"

	# Tables without explicit indexes
	local no_idx_tables
	no_idx_tables=$(sqlite3 "$SQLITE" "SELECT m.name FROM sqlite_master m WHERE m.type='table' AND m.name NOT LIKE 'sqlite_%' AND NOT EXISTS (SELECT 1 FROM pragma_index_list(m.name) WHERE origin='c') ORDER BY m.name;" 2>/dev/null)
	if [[ -n "$no_idx_tables" ]]; then
		echo ""
		echo "  Tables without explicit indexes:"
		echo "$no_idx_tables" | while read -r tbl; do
			[[ -z "$tbl" ]] && continue
			local rowcount
			rowcount=$(sqlite3 "$SQLITE" "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null || echo "?")
			echo -e "    ${YELLOW}${tbl} — ~${rowcount} rows${NC}"
		done
	fi
	echo ""

	# PRAGMA audit
	echo -e "${BOLD}━━━ PRAGMA Settings ━━━${NC}"
	local journal sync cache mmap
	journal=$(sqlite3 "$SQLITE" "PRAGMA journal_mode;" 2>/dev/null)
	sync=$(sqlite3 "$SQLITE" "PRAGMA synchronous;" 2>/dev/null)
	cache=$(sqlite3 "$SQLITE" "PRAGMA cache_size;" 2>/dev/null)
	mmap=$(sqlite3 "$SQLITE" "PRAGMA mmap_size;" 2>/dev/null)
	echo "  journal_mode:    ${journal}"
	echo "  synchronous:     ${sync}"
	echo "  cache_size:      ${cache}"
	echo "  mmap_size:       ${mmap}"
	echo ""

	# Build JSON with SQLite analysis
	NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Collect table info
	echo -e "${BOLD}━━━ Building JSON Report ━━━${NC}"

	QUERIES_JSON="["
	FIRST=true
	rank=0

	# For each table, try EXPLAIN QUERY PLAN on a sample query
	for tbl in $(sqlite3 "$SQLITE" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null); do
		rank=$((rank + 1))
		local rowcount
		rowcount=$(sqlite3 "$SQLITE" "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null || echo "0")
		local sample_sql="SELECT * FROM \"${tbl}\" LIMIT 1"
		local eqp
		eqp=$(sqlite3 "$SQLITE" "EXPLAIN QUERY PLAN ${sample_sql};" 2>/dev/null | head -5 | tr '\n' ' ' || echo "N/A")
		local eqp_escaped
		eqp_escaped=$(echo "$eqp" | sed 's/"/\\"/g')

		local sev="low"
		local score=0
		if [[ "$rowcount" -gt 100000 && "$(echo "$eqp" | grep -c 'SCAN')" -gt 0 ]]; then
			sev="medium"
			score=30
		fi

		[[ "$FIRST" == false ]] && QUERIES_JSON+=","
		FIRST=false

		QUERIES_JSON+="{\"rank\": $rank, \"digest\": \"table_${tbl}\", \"digest_text\": \"Table: ${tbl} (~${rowcount} rows)\", \"query_type\": \"TABLE_SCAN\", \"tables\": \"${tbl}\", \"count_star\": 1, \"total_time_sec\": 0, \"avg_time_ms\": 0, \"explain_plan\": \"${eqp_escaped}\", \"estimated_rows\": ${rowcount:-0}, \"severity\": \"${sev}\", \"severity_score\": ${score}, \"framework_hints\": [], \"db_type\": \"sqlite\"}"
	done
	QUERIES_JSON+="]"

	# Collect index info
	INDEXES_JSON="{"
	FIRST_IDX=true
	for tbl in $(sqlite3 "$SQLITE" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;" 2>/dev/null); do
		local idx_list
		idx_list=$(sqlite3 "$SQLITE" "SELECT name FROM pragma_index_list('${tbl}');" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
		if [[ -n "$idx_list" ]]; then
			[[ "$FIRST_IDX" == false ]] && INDEXES_JSON+=","
			FIRST_IDX=false
			INDEXES_JSON+="\"${tbl}\": [$(echo "$idx_list" | sed 's/,/","/g' | sed 's/^/"/;s/$/"/')]"
		fi
	done
	INDEXES_JSON+="}"

	# Write final JSON
	python3 -c "
import json
doc = {
  'metadata': {'generated_at': '$NOW', 'db_type': 'sqlite', 'file': '$DB_FILE', 'file_size_bytes': ${db_size:-0}, 'source': 'schema_analysis', 'top_n': $TOP_N},
  'server_info': {'version': '$sqlite_ver', 'page_count': ${page_count:-0}, 'page_size': ${page_size:-0}, 'freelist_count': ${freelist:-0}, 'journal_mode': '$journal', 'synchronous': '$sync', 'cache_size': '$cache', 'mmap_size': '$mmap'},
  'summary': {'total_tables': ${table_count:-0}, 'total_indexes': ${idx_count:-0}, 'stat1_entries': ${stat1_count:-0}},
  'queries': json.loads('''$QUERIES_JSON'''),
  'table_info': json.loads('''$INDEXES_JSON'''),
  'processlist': []
}
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
" 2>/dev/null || {
		echo "{\"metadata\": {\"db_type\": \"sqlite\", \"file\": \"$DB_FILE\"}, \"queries\": $QUERIES_JSON, \"table_info\": $INDEXES_JSON}" >"$OUTPUT_FILE"
	}

	echo -e "${GREEN}✓ SQLite analysis report written to ${OUTPUT_FILE}${NC}"

	# Run EXPLAIN QUERY PLAN on larger tables
	if $EXPLAIN_EACH; then
		echo ""
		echo -e "${BOLD}━━━ EXPLAIN QUERY PLAN on Key Tables ━━━${NC}"
		for tbl in $(sqlite3 "$SQLITE" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 10;" 2>/dev/null); do
			local cnt
			cnt=$(sqlite3 "$SQLITE" "SELECT count(*) FROM \"${tbl}\";" 2>/dev/null || echo "0")
			if [[ "$cnt" -gt 1000 ]]; then
				echo ""
				echo "  ${BOLD}Table: ${tbl} (~${cnt} rows)${NC}"
				local cols
				cols=$(sqlite3 "$SQLITE" "SELECT group_concat(name) FROM pragma_table_info('${tbl}');" 2>/dev/null)
				if [[ -n "$cols" ]]; then
					local first_col
					first_col=$(echo "$cols" | cut -d',' -f1)
					sqlite3 "$SQLITE" "EXPLAIN QUERY PLAN SELECT * FROM \"${tbl}\" WHERE \"${first_col}\" = ?;" 2>/dev/null | while read -r line; do
						echo "    $line"
					done
				fi
			fi
		done
		echo ""
	fi
}

# =============================================================================
# DISPATCH
# =============================================================================
case "$DBTYPE" in
mysql)
	run_mysql
	;;
postgresql)
	run_postgresql
	;;
sqlite)
	run_sqlite
	;;
*)
	echo -e "${RED}ERROR: Unknown database type: ${DBTYPE}${NC}"
	echo "  Valid types: mysql, postgresql, sqlite"
	exit 1
	;;
esac

# ---- Done -------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Slow Query Analysis Complete                                ║${NC}"
echo -e "${CYAN}${BOLD}║  Report:     ${OUTPUT_FILE}${NC}"
echo -e "${CYAN}${BOLD}║  DB Type:    ${DBTYPE}${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review ${OUTPUT_FILE} for slow query details"
echo "  2. Run the slow-query-analyzer skill against the output + your repo"
echo "  3. Or manually cross-reference with patterns/<framework>.md"
echo ""
if command -v jq &>/dev/null; then
	echo -e "${GREEN}Quick view with jq:${NC}"
	echo "  jq '.queries[:5] | .[] | {rank, query_type, severity}' ${OUTPUT_FILE}"
fi
echo ""
