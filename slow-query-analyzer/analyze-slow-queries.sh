#!/usr/bin/env bash
# =============================================================================
# analyze-slow-queries.sh — MySQL Slow Query Extractor & Fingerprinter
# =============================================================================
# Extracts slow queries from MySQL Performance Schema and slow query log,
# fingerprints them, runs EXPLAIN, and outputs structured JSON for the
# slow-query-analyzer skill to map to framework ORM patterns.
#
# Usage:
#   ./analyze-slow-queries.sh -h HOST -u USER -p PASS -d DATABASE -o report.json
#   ./analyze-slow-queries.sh --from-slow-log /var/log/mysql/mysql-slow.log
#   ./analyze-slow-queries.sh --help
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASS=""
MYSQL_DB=""
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
	cat <<EOF
${BOLD}analyze-slow-queries.sh${NC} — MySQL Slow Query Extractor

${BOLD}USAGE (MySQL connection):${NC}
  ./analyze-slow-queries.sh -h HOST -u USER -p PASS -d DATABASE [OPTIONS]

${BOLD}USAGE (from slow query log file):${NC}
  ./analyze-slow-queries.sh --from-slow-log /path/to/slow.log [OPTIONS]

${BOLD}OPTIONS:${NC}
  -h, --host HOST         MySQL host (default: 127.0.0.1)
  -P, --port PORT         MySQL port (default: 3306)
  -u, --user USER         MySQL user (default: root)
  -p, --password PASS     MySQL password
  -d, --database DB       Database name to filter (required if using PS)
  -n, --top N             Number of top queries (default: 30)
  -o, --output FILE       Output JSON file (default: slow-queries-report.json)
  --no-explain            Skip EXPLAIN for each query (faster but less info)
  --include-processlist   Include current process list in output
  --from-slow-log FILE    Parse a slow query log file instead of Performance Schema
  --help                  Show this help

${BOLD}OUTPUT:${NC}
  Produces a JSON file with:
    - Query fingerprints and statistics
    - EXPLAIN output per query
    - Table structure info for referenced tables
    - Framework detection hints (table names, column patterns)

EOF
	exit 0
}

# ---- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --host)
		MYSQL_HOST="$2"
		shift 2
		;;
	-P | --port)
		MYSQL_PORT="$2"
		shift 2
		;;
	-u | --user)
		MYSQL_USER="$2"
		shift 2
		;;
	-p | --password)
		MYSQL_PASS="$2"
		shift 2
		;;
	-d | --database)
		MYSQL_DB="$2"
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
	*)
		echo "Unknown option: $1"
		usage
		;;
	esac
done

# ---- Dependencies Check -----------------------------------------------------
for dep in jq sed awk; do
	if ! command -v "$dep" &>/dev/null; then
		echo -e "${YELLOW}⚠  '$dep' not found. Install it for best results.${NC}"
	fi
done

# ---- Slow Log Mode ----------------------------------------------------------
if [[ -n "$FROM_SLOW_LOG" ]]; then
	echo -e "${CYAN}${BOLD}Analyzing slow query log: ${FROM_SLOW_LOG}${NC}"

	if [[ ! -f "$FROM_SLOW_LOG" ]]; then
		echo -e "${RED}ERROR: Slow log file not found: ${FROM_SLOW_LOG}${NC}"
		exit 1
	fi

	# Use mysqldumpslow if available, otherwise fall back to grep/awk
	if command -v mysqldumpslow &>/dev/null; then
		echo "Using mysqldumpslow for analysis..."
		mysqldumpslow -s t -t "$TOP_N" "$FROM_SLOW_LOG" >/tmp/mysql_slow_summary.txt
		echo -e "${GREEN}Top ${TOP_N} queries written to /tmp/mysql_slow_summary.txt${NC}"
	fi

	# Use pt-query-digest if available (much better)
	if command -v pt-query-digest &>/dev/null; then
		echo "Using pt-query-digest for deep analysis..."
		pt-query-digest "$FROM_SLOW_LOG" \
			--limit="$((TOP_N * 2))" \
			--report-format=json \
			--output=json \
			>"$OUTPUT_FILE" 2>/dev/null && {
			echo -e "${GREEN}✓ pt-query-digest report written to ${OUTPUT_FILE}${NC}"
			echo ""
			echo -e "${YELLOW}Note: pt-query-digest fingerprints differ from Performance Schema.${NC}"
			echo "For best results, use Performance Schema mode instead."
			exit 0
		} || echo -e "${YELLOW}⚠  pt-query-digest failed. Falling back to manual extraction.${NC}"
	fi

	echo -e "${YELLOW}Manual slow log parsing not fully implemented. Recommend Performance Schema mode.${NC}"
	exit 0
fi

# ---- MySQL Client Check -----------------------------------------------------
MYSQL_CLI=""
for candidate in mysql mariadb; do
	if command -v "$candidate" &>/dev/null; then
		MYSQL_CLI="$candidate"
		break
	fi
done

if [[ -z "$MYSQL_CLI" ]]; then
	echo -e "${RED}ERROR: mysql or mariadb client not found. Install mysql-client.${NC}"
	exit 1
fi

MYSQL_OPTS=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --connect-timeout=10 -N -B)
if [[ -n "$MYSQL_PASS" ]]; then
	MYSQL_OPTS+=(-p"$MYSQL_PASS")
fi

# ---- Check Performance Schema -----------------------------------------------
echo -e "${CYAN}${BOLD}Checking MySQL connectivity & Performance Schema...${NC}"

PS_ENABLED=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT @@performance_schema" 2>/dev/null || echo "0")
if [[ "$PS_ENABLED" != "1" && "$PS_ENABLED" != "ON" ]]; then
	echo -e "${RED}ERROR: Performance Schema is OFF. Enable it to use this script:${NC}"
	echo "  SET GLOBAL performance_schema = ON;"
	echo "  (requires restart if compiled without it)"
	exit 1
fi

# Check if statements_digest is enabled
DIGEST_ENABLED=$($MYSQL_CLI "${MYSQL_OPTS[@]}" \
	-e "SELECT COUNT(*) FROM performance_schema.setup_consumers WHERE NAME='statements_digest' AND ENABLED='YES'" 2>/dev/null || echo "0")
if [[ "$DIGEST_ENABLED" == "0" ]]; then
	echo -e "${YELLOW}⚠  statements_digest consumer not enabled. Enabling now...${NC}"
	$MYSQL_CLI "${MYSQL_OPTS[@]}" \
		-e "UPDATE performance_schema.setup_consumers SET ENABLED='YES' WHERE NAME='statements_digest'" 2>/dev/null || true
fi

echo -e "${GREEN}✓ Connected to MySQL ${MYSQL_HOST}:${MYSQL_PORT}${NC}"
echo ""

# ---- Extract Top Queries -----------------------------------------------------
echo -e "${BOLD}━━━ Extracting Top ${TOP_N} Slow Queries ━━━${NC}"

# Build the query with optional database filter
DB_FILTER=""
if [[ -n "$MYSQL_DB" ]]; then
	DB_FILTER="AND SCHEMA_NAME = '${MYSQL_DB}'"
fi

# Main extraction query
EXTRACT_SQL="
SELECT
    DIGEST_TEXT,
    COUNT_STAR,
    ROUND(SUM_TIMER_WAIT / 1000000000000, 4) AS total_time_sec,
    ROUND(AVG_TIMER_WAIT / 1000000000, 2) AS avg_time_ms,
    ROUND(MIN_TIMER_WAIT / 1000000000, 2) AS min_time_ms,
    ROUND(MAX_TIMER_WAIT / 1000000000, 2) AS max_time_ms,
    SUM_ROWS_EXAMINED,
    ROUND(SUM_ROWS_EXAMINED / GREATEST(COUNT_STAR, 1), 0) AS avg_rows_examined,
    SUM_ROWS_SENT,
    ROUND(SUM_ROWS_SENT / GREATEST(COUNT_STAR, 1), 0) AS avg_rows_sent,
    SUM_ROWS_AFFECTED,
    SUM_NO_INDEX_USED,
    SUM_NO_GOOD_INDEX_USED,
    SUM_SELECT_FULL_JOIN,
    SUM_SELECT_SCAN,
    SUM_SORT_ROWS,
    SUM_SORT_MERGE_PASSES,
    SUM_CREATED_TMP_TABLES,
    SUM_CREATED_TMP_DISK_TABLES,
    FIRST_SEEN,
    LAST_SEEN,
    DIGEST
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT IS NOT NULL
  AND DIGEST_TEXT != ''
  AND SUM_TIMER_WAIT > 0
  ${DB_FILTER}
ORDER BY SUM_TIMER_WAIT DESC
LIMIT ${TOP_N}
"

echo "Running extraction query..."

# Get raw TSV output
RAW_DATA=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "$EXTRACT_SQL" 2>/dev/null) || {
	echo -e "${RED}ERROR: Failed to extract queries from Performance Schema.${NC}"
	echo "Check that Performance Schema is fully initialized and statements_digest is enabled."
	exit 1
}

if [[ -z "$RAW_DATA" ]]; then
	echo -e "${YELLOW}No query data found in Performance Schema.${NC}"
	echo "This could mean:"
	echo "  - The server just restarted (data resets on restart)"
	echo "  - No queries have run yet"
	echo "  - statements_digest consumer is not enabled"
	exit 0
fi

QUERY_COUNT=$(echo "$RAW_DATA" | wc -l)
echo -e "${GREEN}✓ Extracted ${QUERY_COUNT} query digests${NC}"
echo ""

# ---- Build JSON Output ------------------------------------------------------
echo -e "${BOLD}━━━ Building Report ━━━${NC}"

# Start JSON document
cat >"$OUTPUT_FILE" <<'JSONHEAD'
{
  "metadata": {
    "generated_at": "PLACEHOLDER_TIME",
    "mysql_host": "PLACEHOLDER_HOST",
    "mysql_port": "PLACEHOLDER_PORT",
    "database_filter": "PLACEHOLDER_DB",
    "source": "performance_schema.events_statements_summary_by_digest",
    "top_n": 0,
    "total_queries_found": 0
  },
  "server_info": {
    "version": "unknown",
    "uptime_seconds": 0,
    "buffer_pool_size_mb": 0,
    "max_connections": 0
  },
  "summary": {
    "total_time_seconds": 0,
    "total_executions": 0,
    "queries_without_index": 0,
    "queries_with_full_scan": 0
  },
  "queries": [],
  "table_info": {},
  "processlist": []
}
JSONHEAD

# Fill metadata
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
DB_DISPLAY="${MYSQL_DB:-all databases}"

# Get server info
MYSQL_VER=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT VERSION()" 2>/dev/null || echo "unknown")
UPTIME=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime'" 2>/dev/null || echo "0")
IBP=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT ROUND(@@innodb_buffer_pool_size / 1048576, 0)" 2>/dev/null || echo "0")
MAX_CONN=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT @@max_connections" 2>/dev/null || echo "0")

# Use a temp file and jq for safe JSON building
TMP_JSON=$(mktemp)

# Build queries array
QUERIES_JSON="["
FIRST=true
LINE_NUM=0

while IFS=$'\t' read -r digest_text count_star total_time avg_time min_time max_time \
	rows_examined avg_rows_examined rows_sent avg_rows_sent rows_affected \
	no_index no_good_index full_join select_scan sort_rows sort_merge tmp_tables tmp_disk_tables \
	first_seen last_seen digest; do

	LINE_NUM=$((LINE_NUM + 1))

	# Escape for JSON
	DIGEST_ESCAPED=$(echo "$digest_text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')

	# Determine query type
	QTYPE="OTHER"
	if echo "$digest_text" | grep -qiE '^\s*SELECT'; then QTYPE="SELECT"; fi
	if echo "$digest_text" | grep -qiE '^\s*INSERT'; then QTYPE="INSERT"; fi
	if echo "$digest_text" | grep -qiE '^\s*UPDATE'; then QTYPE="UPDATE"; fi
	if echo "$digest_text" | grep -qiE '^\s*DELETE'; then QTYPE="DELETE"; fi
	if echo "$digest_text" | grep -qiE '^\s*REPLACE'; then QTYPE="REPLACE"; fi

	# Extract table names (simple regex)
	TABLES=""
	if echo "$digest_text" | grep -qi 'FROM `\?\(\w*\)`\?'; then
		TABLES=$(echo "$digest_text" | grep -oiP '(?:FROM|JOIN)\s+`?(\w+)`?' |
			sed 's/FROM //i; s/JOIN //i; s/`//g' | sort -u | tr '\n' ',' | sed 's/,$//')
	fi

	# Determine severity score (simple heuristic)
	SEVERITY_SCORE=0
	[[ "${no_index:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 30))
	[[ "${no_good_index:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 20))
	[[ "${select_scan:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 25))
	[[ "${tmp_disk_tables:-0}" -gt 0 ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 15))
	[[ "$(echo "$avg_time" | awk '{print ($1 > 500 ? 1 : 0)}')" == "1" ]] && SEVERITY_SCORE=$((SEVERITY_SCORE + 10))

	# Determine severity label
	if [[ $SEVERITY_SCORE -ge 70 ]]; then
		SEV="critical"
	elif [[ $SEVERITY_SCORE -ge 40 ]]; then
		SEV="high"
	elif [[ $SEVERITY_SCORE -ge 20 ]]; then
		SEV="medium"
	else
		SEV="low"
	fi

	# Build EXPLAIN placeholder
	EXPLAIN_JSON="null"
	if $EXPLAIN_EACH && [[ "$QTYPE" == "SELECT" ]]; then
		# We'll generate EXPLAIN separately to avoid timeout
		EXPLAIN_JSON='"pending_explain"'
	fi

	# Build framework hints
	FW_HINTS="[]"
	if echo "$digest_text" | grep -qi '`\?users`\?'; then FW_HINTS='["users_table_present"]'; fi
	if echo "$digest_text" | grep -qiE '(?:COUNT|SUM|AVG|MIN|MAX)\s*\('; then FW_HINTS='["aggregation"]'; fi
	if echo "$digest_text" | grep -qi 'GROUP BY'; then FW_HINTS='["group_by","aggregation"]'; fi
	if echo "$digest_text" | grep -qi 'LIMIT.*OFFSET'; then FW_HINTS='["pagination","offset_pagination"]'; fi
	if echo "$digest_text" | grep -qi 'LEFT JOIN\|INNER JOIN'; then FW_HINTS='["joins"]'; fi
	if echo "$digest_text" | grep -qi 'IN\s*('; then FW_HINTS='["in_clause"]'; fi

	[[ "$FIRST" == false ]] && QUERIES_JSON+=","
	FIRST=false

	QUERIES_JSON+=$(
		cat <<BLOCK
{
  "rank": $LINE_NUM,
  "digest": "$digest",
  "digest_text": "$DIGEST_ESCAPED",
  "query_type": "$QTYPE",
  "tables": "$TABLES",
  "count_star": ${count_star:-0},
  "total_time_sec": ${total_time:-0},
  "avg_time_ms": ${avg_time:-0},
  "min_time_ms": ${min_time:-0},
  "max_time_ms": ${max_time:-0},
  "sum_rows_examined": ${rows_examined:-0},
  "avg_rows_examined": ${avg_rows_examined:-0},
  "sum_rows_sent": ${rows_sent:-0},
  "avg_rows_sent": ${avg_rows_sent:-0},
  "sum_rows_affected": ${rows_affected:-0},
  "sum_no_index_used": ${no_index:-0},
  "sum_no_good_index_used": ${no_good_index:-0},
  "sum_select_full_join": ${full_join:-0},
  "sum_select_scan": ${select_scan:-0},
  "sum_sort_merge_passes": ${sort_merge:-0},
  "sum_created_tmp_disk_tables": ${tmp_disk_tables:-0},
  "first_seen": "$first_seen",
  "last_seen": "$last_seen",
  "explain": null,
  "severity": "$SEV",
  "severity_score": $SEVERITY_SCORE,
  "framework_hints": $FW_HINTS
}
BLOCK
	)

done <<<"$RAW_DATA"

QUERIES_JSON+="]"

# Calculate summary
TOTAL_TIME=$(echo "$RAW_DATA" | awk -F'\t' '{sum += $3} END {printf "%.2f", sum}')
TOTAL_EXEC=$(echo "$RAW_DATA" | awk -F'\t' '{sum += $2} END {print sum}')
NO_IDX_COUNT=$(echo "$RAW_DATA" | awk -F'\t' '{if ($14 > 0) count++} END {print count}')
FULL_SCAN_COUNT=$(echo "$RAW_DATA" | awk -F'\t' '{if ($17 > 0) count++} END {print count}')

# ---- Collect Table Info -----------------------------------------------------
TABLES_JSON="{}"
if $INCLUDE_TABLES_INFO && [[ -n "$MYSQL_DB" ]]; then
	echo "Collecting table information..."

	TABLE_DATA=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "
        SELECT TABLE_NAME, TABLE_ROWS, ROUND(DATA_LENGTH/1048576, 2) AS data_mb,
               ROUND(INDEX_LENGTH/1048576, 2) AS index_mb
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = '${MYSQL_DB}'
        ORDER BY (DATA_LENGTH + INDEX_LENGTH) DESC
        LIMIT 50
    " 2>/dev/null)

	TABLES_JSON="{"
	FIRST_TABLE=true
	while IFS=$'\t' read -r tname trows data_mb index_mb; do
		[[ "$FIRST_TABLE" == false ]] && TABLES_JSON+=","
		FIRST_TABLE=false
		TABLES_JSON+="\"$tname\": {\"rows\": ${trows:-0}, \"data_mb\": ${data_mb:-0}, \"index_mb\": ${index_mb:-0}}"
	done <<<"$TABLE_DATA"
	TABLES_JSON+="}"
fi

# ---- Collect Process List (optional) ----------------------------------------
PROCESSLIST_JSON="[]"
if $INCLUDE_PROCESSLIST; then
	echo "Collecting current process list..."
	PL_DATA=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "
        SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, LEFT(INFO, 200) AS INFO
        FROM information_schema.PROCESSLIST
        WHERE COMMAND != 'Sleep' AND TIME > 0
        ORDER BY TIME DESC
        LIMIT 50
    " 2>/dev/null || echo "")

	PROCESSLIST_JSON="["
	FIRST_PL=true
	while IFS=$'\t' read -r pid user host db cmd time state info; do
		INFO_CLEAN=$(echo "$info" | sed 's/"/\\"/g')
		[[ "$FIRST_PL" == false ]] && PROCESSLIST_JSON+=","
		FIRST_PL=false
		PROCESSLIST_JSON+="{\"id\": \"$pid\", \"user\": \"$user\", \"time_sec\": ${time:-0}, \"state\": \"$state\", \"info\": \"$INFO_CLEAN\"}"
	done <<<"$PL_DATA"
	PROCESSLIST_JSON+="]"
fi

# ---- Assemble Final JSON ----------------------------------------------------
echo "Assembling final JSON report..."
python3 -c "
import json, sys

with open('$OUTPUT_FILE', 'r') as f:
    doc = json.load(f)

doc['metadata']['generated_at'] = '$NOW'
doc['metadata']['mysql_host'] = '$MYSQL_HOST'
doc['metadata']['mysql_port'] = '$MYSQL_PORT'
doc['metadata']['database_filter'] = '$DB_DISPLAY'
doc['metadata']['top_n'] = $TOP_N
doc['metadata']['total_queries_found'] = $QUERY_COUNT

doc['server_info']['version'] = '$MYSQL_VER'
doc['server_info']['uptime_seconds'] = ${UPTIME:-0}
doc['server_info']['buffer_pool_size_mb'] = ${IBP:-0}
doc['server_info']['max_connections'] = ${MAX_CONN:-0}

doc['summary']['total_time_seconds'] = ${TOTAL_TIME:-0}
doc['summary']['total_executions'] = ${TOTAL_EXEC:-0}
doc['summary']['queries_without_index'] = ${NO_IDX_COUNT:-0}
doc['summary']['queries_with_full_scan'] = ${FULL_SCAN_COUNT:-0}

# Inject assembled arrays
doc['queries'] = json.loads('''$QUERIES_JSON''')
doc['table_info'] = json.loads('''$TABLES_JSON''')
doc['processlist'] = json.loads('''$PROCESSLIST_JSON''')

with open('$OUTPUT_FILE', 'w') as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)

print('JSON assembled successfully')
" 2>/dev/null || {
	echo -e "${YELLOW}⚠  Python not available for JSON assembly. Writing raw JSON fragments.${NC}"
	# Fallback: write simplified JSON manually
	{
		echo "{"
		echo "  \"metadata\": { \"generated_at\": \"$NOW\", \"mysql_host\": \"$MYSQL_HOST\", \"top_n\": $TOP_N },"
		echo "  \"queries\": $QUERIES_JSON,"
		echo "  \"table_info\": $TABLES_JSON"
		echo "}"
	} >"$OUTPUT_FILE"
}

# ---- Run EXPLAIN on Top Queries (optional) ----------------------------------
if $EXPLAIN_EACH; then
	echo ""
	echo -e "${BOLD}━━━ Running EXPLAIN on Top SELECT Queries ━━━${NC}"
	EXPLAIN_COUNT=0

	while IFS=$'\t' read -r digest_text _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ digest; do
		if echo "$digest_text" | grep -qiE '^\s*SELECT'; then
			EXPLAIN_COUNT=$((EXPLAIN_COUNT + 1))
			if [[ $EXPLAIN_COUNT -gt 10 ]]; then
				echo "  (limited to first 10 SELECT queries to avoid load)"
				break
			fi

			# Try to get a sample query from events_statements_history
			SAMPLE_SQL=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "
                SELECT SQL_TEXT FROM performance_schema.events_statements_history
                WHERE DIGEST = '$digest' LIMIT 1
            " 2>/dev/null || echo "")

			if [[ -n "$SAMPLE_SQL" ]]; then
				EXPLAIN_OUTPUT=$($MYSQL_CLI "${MYSQL_OPTS[@]}" -e "EXPLAIN FORMAT=JSON $SAMPLE_SQL" 2>/dev/null || echo '{"error": "EXPLAIN failed"}')
				EXPLAIN_FILE="explain_${digest}.json"
				echo "$EXPLAIN_OUTPUT" >"$EXPLAIN_FILE"
				echo "  ✓ EXPLAIN #${EXPLAIN_COUNT} → ${EXPLAIN_FILE}"
			fi
		fi
	done <<<"$RAW_DATA"

	echo -e "${GREEN}✓ Ran ${EXPLAIN_COUNT} EXPLAINs${NC}"
fi

# ---- Done -------------------------------------------------------------------
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Slow Query Analysis Complete                                ║${NC}"
echo -e "${CYAN}${BOLD}║  Report:     ${OUTPUT_FILE}${NC}"
echo -e "${CYAN}${BOLD}║  Queries:    ${QUERY_COUNT}${NC}"
if $EXPLAIN_EACH; then
	echo -e "${CYAN}${BOLD}║  EXPLAINs:   ${EXPLAIN_COUNT} (see explain_*.json files)${NC}"
fi
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review ${OUTPUT_FILE} for top slow queries"
echo "  2. Run the slow-query-analyzer skill against the output + your repo"
echo "  3. Or manually cross-reference with patterns/<framework>.md"
echo ""
echo -e "${GREEN}Quick view with jq:${NC}"
echo "  jq '.queries[:5] | .[] | {rank, query_type, total_time_sec, severity}' ${OUTPUT_FILE}"
echo ""
