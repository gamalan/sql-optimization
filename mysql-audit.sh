#!/usr/bin/env bash
# =============================================================================
# mysql-audit.sh — MySQL 8.0 Audit & Configuration Optimizer
# =============================================================================
# Audits a self-managed MySQL 8.0 instance with primary + replicas topology
# and generates an optimized my.cnf for mixed OLTP (read/write) workloads.
#
# Usage:
#   chmod +x mysql-audit.sh
#   ./mysql-audit.sh                          # interactive (prompts for creds)
#   ./mysql-audit.sh -h HOST -u USER -p PASS  # non-interactive
#   ./mysql-audit.sh --help
#
# Output:
#   - Current configuration report (stdout)
#   - mysql-optimized.cnf (generated config)
#   - mysql-audit-report.txt (full audit report)
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASS="${MYSQL_PASS:-}"
OUTPUT_CNF="mysql-optimized.cnf"
OUTPUT_REPORT="mysql-audit-report.txt"
TOTAL_RAM_MB=""
ROLE="primary"  # primary | replica
WORKLOAD="oltp" # oltp | read-heavy | write-heavy | balanced

# ---- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---- Help -------------------------------------------------------------------
usage() {
	cat <<EOF
${BOLD}mysql-audit.sh${NC} — MySQL 8.0 Configuration Auditor & Optimizer

${BOLD}USAGE:${NC}
  ./mysql-audit.sh [OPTIONS]

${BOLD}OPTIONS:${NC}
  -h, --host HOST      MySQL host (default: 127.0.0.1)
  -P, --port PORT      MySQL port (default: 3306)
  -u, --user USER      MySQL user (default: root)
  -p, --password PASS  MySQL password
  -r, --role ROLE      Server role: primary | replica (default: primary)
  -m, --ram MB         Total system RAM in MB (auto-detected if omitted)
  -w, --workload TYPE  Workload type: oltp | read-heavy | write-heavy | balanced
  --help               Show this help

${BOLD}EXAMPLES:${NC}
  ./mysql-audit.sh
  ./mysql-audit.sh -h db-primary.internal -u admin -p secret -r primary
  ./mysql-audit.sh -h db-replica-1.internal -u admin -p secret -r replica

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
	-r | --role)
		ROLE="$2"
		shift 2
		;;
	-m | --ram)
		TOTAL_RAM_MB="$2"
		shift 2
		;;
	-w | --workload)
		WORKLOAD="$2"
		shift 2
		;;
	--help) usage ;;
	*)
		echo "Unknown option: $1"
		usage
		;;
	esac
done

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

MYSQL_OPTS=(-h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" --connect-timeout=10)
if [[ -n "$MYSQL_PASS" ]]; then
	MYSQL_OPTS+=(-p"$MYSQL_PASS")
fi

# Quick connectivity check
if ! $MYSQL_CLI "${MYSQL_OPTS[@]}" -e "SELECT 1" &>/dev/null; then
	echo -e "${RED}ERROR: Cannot connect to MySQL at ${MYSQL_HOST}:${MYSQL_PORT}${NC}"
	echo "Check host, port, credentials, and that the server is running."
	exit 1
fi

# ---- Helper: run a query silently -------------------------------------------
sql() {
	$MYSQL_CLI "${MYSQL_OPTS[@]}" -N -B -e "$1" 2>/dev/null || echo "QUERY_ERROR"
}

# ---- System Info ------------------------------------------------------------
detect_system() {
	echo -e "${BOLD}━━━ System Information ━━━${NC}"

	# Try to get RAM from the MySQL host (if we can access /proc/meminfo via the same machine)
	if [[ -z "$TOTAL_RAM_MB" ]]; then
		if [[ -f /proc/meminfo ]]; then
			TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
		elif command -v free &>/dev/null; then
			TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
		else
			# Fallback: estimate from InnoDB buffer pool + 30% overhead
			local ibp
			ibp=$(sql "SELECT @@innodb_buffer_pool_size" | head -1)
			if [[ "$ibp" =~ ^[0-9]+$ ]]; then
				TOTAL_RAM_MB=$(((ibp / 1048576) * 100 / 60))
			else
				TOTAL_RAM_MB=8192 # Safe default: 8 GB
				echo -e "  ${YELLOW}⚠  Could not detect RAM. Assuming ${TOTAL_RAM_MB} MB. Use -m to override.${NC}"
			fi
		fi
	fi
	echo "  Total RAM:        ${GREEN}${TOTAL_RAM_MB} MB${NC}"

	local cpu_cores
	cpu_cores=$(nproc 2>/dev/null || echo "4")
	echo "  CPU cores:        ${cpu_cores}"

	echo ""
}

# ---- MySQL Version & Uptime -------------------------------------------------
check_version() {
	echo -e "${BOLD}━━━ MySQL Version & Uptime ━━━${NC}"

	local ver uptime
	ver=$(sql "SELECT VERSION()")
	uptime=$(sql "SELECT TIME_FORMAT(SEC_TO_TIME(VARIABLE_VALUE), '%Hh %im') FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime'")

	echo "  Version:          ${GREEN}${ver}${NC}"
	echo "  Uptime:           ${uptime}"

	# Warn on MySQL 5.7
	if [[ "$ver" == 5.7.* ]]; then
		echo -e "  ${YELLOW}⚠  MySQL 5.7 detected. Consider upgrading to 8.0 for better performance.${NC}"
	fi

	local edition
	edition=$(sql "SELECT @@version_comment")
	echo "  Edition:          ${edition}"

	echo ""
}

# ---- InnoDB Configuration ---------------------------------------------------
check_innodb() {
	echo -e "${BOLD}━━━ InnoDB Engine Configuration ━━━${NC}"

	local ibp ibp_human ibp_of_ram
	ibp=$(sql "SELECT @@innodb_buffer_pool_size")
	ibp=$(echo "$ibp" | head -1 | tr -d '[:space:]')
	ibp_human=$(numfmt --to=iec --suffix=B "$ibp" 2>/dev/null || echo "${ibp} bytes")
	ibp_of_ram=$(awk "BEGIN {printf \"%.0f\", ($ibp / 1048576) / $TOTAL_RAM_MB * 100}")

	echo "  Buffer Pool Size: ${GREEN}${ibp_human}${NC} (${ibp_of_ram}% of RAM)"

	if ((ibp_of_ram < 50)); then
		echo -e "    ${YELLOW}⚠  Low. Recommend 60-70% of RAM for dedicated MySQL server.${NC}"
	elif ((ibp_of_ram > 80)); then
		echo -e "    ${YELLOW}⚠  High. Leave RAM for OS, connections, and other buffers.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy range${NC}"
	fi

	local ibp_instances
	ibp_instances=$(sql "SELECT @@innodb_buffer_pool_instances")
	echo "  Pool Instances:   ${ibp_instances}"

	local recommended_instances=$((ibp / 1073741824 > 1 ? (ibp / 1073741824 > 8 ? 8 : ibp / 1073741824) : ibp / 1073741824))
	if ((ibp_instances < cpu_cores && ibp_instances < 8)); then
		echo -e "    ${YELLOW}⚠  Consider increasing to min(CPU cores, 8) for concurrency.${NC}"
	fi

	# Log file size
	local log_size
	log_size=$(sql "SELECT @@innodb_log_file_size")
	log_size=$(echo "$log_size" | head -1 | tr -d '[:space:]')
	local log_size_human
	log_size_human=$(numfmt --to=iec --suffix=B "$log_size" 2>/dev/null || echo "${log_size} bytes")
	echo "  Log File Size:    ${log_size_human}"

	local log_size_mb=$((log_size / 1048576))
	local recommended_log_size_mb=$(((ibp / 1048576) / 4 > 512 ? (ibp / 1048576) / 4 : 512))
	if ((log_size_mb < 512)); then
		echo -e "    ${RED}✗ Very small. Recommend ${recommended_log_size_mb}MB for write performance.${NC}"
	elif ((log_size_mb < recommended_log_size_mb / 2)); then
		echo -e "    ${YELLOW}⚠  Consider ${recommended_log_size_mb}MB for better write throughput.${NC}"
	else
		echo -e "    ${GREEN}✓ Good${NC}"
	fi

	# Log buffer size
	local log_buf
	log_buf=$(sql "SELECT @@innodb_log_buffer_size")
	log_buf=$(echo "$log_buf" | head -1 | tr -d '[:space:]')
	local log_buf_human
	log_buf_human=$(numfmt --to=iec --suffix=B "$log_buf" 2>/dev/null || echo "${log_buf} bytes")
	echo "  Log Buffer Size:  ${log_buf_human}"

	local log_buf_mb=$((log_buf / 1048576))
	if ((log_buf_mb < 64)); then
		echo -e "    ${YELLOW}⚠  Increase to 64-256MB for write-heavy workloads.${NC}"
	fi

	# Flush method
	local flush
	flush=$(sql "SELECT @@innodb_flush_method")
	echo "  Flush Method:     ${flush}"
	if [[ "$flush" != "O_DIRECT" && "$flush" != "O_DIRECT_NO_FSYNC" ]]; then
		echo -e "    ${YELLOW}⚠  Use O_DIRECT on Linux to avoid double-buffering.${NC}"
	fi

	# Flush log at trx commit
	local flush_log
	flush_log=$(sql "SELECT @@innodb_flush_log_at_trx_commit")
	echo "  Flush Log Commit: ${flush_log}"

	case "$flush_log" in
	1) echo -e "    ${GREEN}✓ Full ACID. Best for primary. Slightly slower writes.${NC}" ;;
	2) echo -e "    ${YELLOW}⚠  Flush to OS cache. Fast but loses 1s of data on crash.${NC}" ;;
	0) echo -e "    ${YELLOW}⚠  Flush every second. OK for replicas, risky for primaries.${NC}" ;;
	esac

	# IO capacity
	local io_cap
	io_cap=$(sql "SELECT @@innodb_io_capacity")
	local io_cap_max
	io_cap_max=$(sql "SELECT @@innodb_io_capacity_max")
	echo "  IO Capacity:      ${io_cap} (max: ${io_cap_max})"

	if ((io_cap < 2000)); then
		echo -e "    ${YELLOW}⚠  Modern SSDs can handle 2000-4000. Increase for better background throughput.${NC}"
	fi

	# Read IO threads
	local read_threads write_threads
	read_threads=$(sql "SELECT @@innodb_read_io_threads")
	write_threads=$(sql "SELECT @@innodb_write_io_threads")
	echo "  IO Threads:       read=${read_threads}, write=${write_threads}"
	if ((read_threads < 8)); then
		echo -e "    ${YELLOW}⚠  Increase to 8-16 on multi-core systems.${NC}"
	fi

	# Adaptive hash index
	local ahi
	ahi=$(sql "SELECT @@innodb_adaptive_hash_index")
	echo "  Adaptive Hash:    ${ahi}"

	local ahi_parts
	ahi_parts=$(sql "SELECT @@innodb_adaptive_hash_index_parts")
	echo "  AHI Partitions:   ${ahi_parts}"
	if ((ahi_parts < 8 && ahi == "ON")); then
		echo -e "    ${YELLOW}⚠  Increase to 8-32 on multi-core for less contention.${NC}"
	fi

	echo ""
}

# ---- Connection & Thread Configuration --------------------------------------
check_connections() {
	echo -e "${BOLD}━━━ Connection & Thread Configuration ━━━${NC}"

	local max_conn
	max_conn=$(sql "SELECT @@max_connections")
	echo "  Max Connections:  ${max_conn}"

	# Check current connections
	local used_conn
	used_conn=$(sql "SELECT COUNT(*) FROM performance_schema.processlist WHERE USER != 'system user'" 2>/dev/null || echo "0")
	echo "  Active (non-sys): ${used_conn}"

	local conn_pct
	conn_pct=$(awk "BEGIN {printf \"%.0f\", ($used_conn / $max_conn) * 100}" 2>/dev/null)
	if [[ -n "$conn_pct" ]] && ((conn_pct > 80)); then
		echo -e "    ${RED}✗ ${conn_pct}% used. Increase max_connections or use connection pooling!${NC}"
	fi

	local thread_cache
	thread_cache=$(sql "SELECT @@thread_cache_size")
	echo "  Thread Cache:     ${thread_cache}"

	local threads_created
	threads_created=$(sql "SHOW GLOBAL STATUS LIKE 'Threads_created'" | awk '{print $2}')
	local threads_connected
	threads_connected=$(sql "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
	threads_created=${threads_created:-0}
	threads_connected=${threads_connected:-1}
	local cache_hit
	cache_hit=$(awk "BEGIN {printf \"%.1f\", 100 - ($threads_created / ($threads_connected + 1)) * 100}")
	echo "  Thread Cache Hit: ${cache_hit}%"

	if (($(echo "$cache_hit < 90" | bc -l 2>/dev/null || echo 1))); then
		echo -e "    ${YELLOW}⚠  Thread cache hit rate below 90%. Increase thread_cache_size.${NC}"
	fi

	# Connection memory estimate
	local conn_buffers=(
		"sort_buffer_size"
		"read_buffer_size"
		"read_rnd_buffer_size"
		"join_buffer_size"
		"binlog_cache_size"
	)
	local per_conn_mb=0
	for var in "${conn_buffers[@]}"; do
		local val
		val=$(sql "SELECT @@${var}" | head -1 | tr -d '[:space:]')
		per_conn_mb=$((per_conn_mb + (val / 1048576)))
	done

	local max_conn_mem=$((per_conn_mb * max_conn))
	local max_conn_mem_pct
	max_conn_mem_pct=$(awk "BEGIN {printf \"%.0f\", ($max_conn_mem / $TOTAL_RAM_MB) * 100}")

	echo "  Per-conn buffer:  ${per_conn_mb} MB"
	echo "  Max conn memory:  ${max_conn_mem} MB (${max_conn_mem_pct}% of RAM)"
	if ((max_conn_mem_pct > 50)); then
		echo -e "    ${RED}✗ Connection buffers could consume ${max_conn_mem_pct}% RAM!${NC}"
		echo "      Reduce max_connections or use connection pooling (ProxySQL, HikariCP, etc.)"
	fi

	echo ""
}

# ---- Replication Status -----------------------------------------------------
check_replication() {
	echo -e "${BOLD}━━━ Replication Status ━━━${NC}"

	local slave_status
	slave_status=$(sql "SHOW SLAVE STATUS\G" 2>/dev/null || echo "")

	if [[ -z "$slave_status" ]]; then
		echo "  ${YELLOW}Not a replica (no SLAVE STATUS)${NC}"
		echo ""

		# Primary info
		local binlog_on
		binlog_on=$(sql "SELECT @@log_bin")
		echo "  Binary Log:       ${binlog_on}"
		if [[ "$binlog_on" == "0" || "$binlog_on" == "OFF" ]]; then
			echo -e "    ${RED}✗ Binary logging OFF. Enable for replication and PITR.${NC}"
		fi

		local binlog_format
		binlog_format=$(sql "SELECT @@binlog_format")
		echo "  Binlog Format:    ${binlog_format}"
		if [[ "$binlog_format" != "ROW" ]]; then
			echo -e "    ${YELLOW}⚠  Use ROW format for safety and consistency.${NC}"
		fi

		local sync_binlog
		sync_binlog=$(sql "SELECT @@sync_binlog")
		echo "  Sync Binlog:      ${sync_binlog}"
		if [[ "$sync_binlog" == "0" ]]; then
			echo -e "    ${RED}✗ sync_binlog=0 risks data loss on crash.${NC}"
		fi

		local gtid
		gtid=$(sql "SELECT @@gtid_mode")
		echo "  GTID Mode:        ${gtid}"
		if [[ "$gtid" == "OFF" ]]; then
			echo -e "    ${YELLOW}⚠  Enable GTID for easier failover and replication management.${NC}"
		fi

		# Replica connections
		local replica_count
		replica_count=$(sql "SHOW SLAVE HOSTS" 2>/dev/null | wc -l)
		echo "  Connected Replicas: $((replica_count > 0 ? replica_count - 1 : 0))"
	else
		# Parse replica status
		local io_thread sql_thread secs_behind
		io_thread=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
		sql_thread=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')
		secs_behind=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')

		echo "  IO Thread:        ${io_thread}"
		echo "  SQL Thread:       ${sql_thread}"

		if [[ "$io_thread" == "Yes" && "$sql_thread" == "Yes" ]]; then
			echo -e "    ${GREEN}✓ Replication healthy${NC}"
		else
			echo -e "    ${RED}✗ Replication broken!${NC}"
		fi

		if [[ -n "$secs_behind" && "$secs_behind" != "NULL" ]]; then
			echo "  Seconds Behind:   ${secs_behind}"
			if ((secs_behind > 10)); then
				echo -e "    ${RED}✗ Replica is ${secs_behind}s behind primary!${NC}"
			fi
		fi

		# Parallel replication
		local parallel_workers
		parallel_workers=$(sql "SELECT @@slave_parallel_workers")
		echo "  Parallel Workers: ${parallel_workers}"
		if ((parallel_workers < 4)); then
			echo -e "    ${YELLOW}⚠  Increase slave_parallel_workers to 4-8 for faster replication.${NC}"
		fi

		local parallel_type
		parallel_type=$(sql "SELECT @@slave_parallel_type")
		echo "  Parallel Type:    ${parallel_type}"
		if [[ "$parallel_type" != "LOGICAL_CLOCK" ]]; then
			echo -e "    ${YELLOW}⚠  Use LOGICAL_CLOCK for better parallelism.${NC}"
		fi

		# Read-only
		local read_only
		read_only=$(sql "SELECT @@read_only")
		echo "  Read Only:        ${read_only}"
		if [[ "$read_only" == "0" || "$read_only" == "OFF" ]]; then
			echo -e "    ${RED}✗ Replicas should have read_only=ON to prevent accidental writes!${NC}"
		fi

		local super_read_only
		super_read_only=$(sql "SELECT @@super_read_only")
		echo "  Super Read Only:  ${super_read_only}"
		if [[ "$super_read_only" == "0" || "$super_read_only" == "OFF" ]]; then
			echo -e "    ${YELLOW}⚠  Set super_read_only=ON on replicas.${NC}"
		fi
	fi

	echo ""
}

# ---- Query Cache (deprecated in 8.0) ----------------------------------------
check_query_cache() {
	local qc_size
	qc_size=$(sql "SELECT @@query_cache_size" 2>/dev/null || echo "0")
	if [[ "$qc_size" != "0" && "$qc_size" != "0" ]]; then
		echo -e "${YELLOW}⚠  query_cache_size=${qc_size}. The query cache is deprecated in MySQL 8.0 and removed in 8.0.3+.${NC}"
		echo -e "   Set query_cache_type=0 and query_cache_size=0."
		echo ""
	fi
}

# ---- Temp Tables & Sort Buffers ---------------------------------------------
check_temp_tables() {
	echo -e "${BOLD}━━━ Temporary Tables & Sort Configuration ━━━${NC}"

	local tmp_table_size
	tmp_table_size=$(sql "SELECT @@tmp_table_size")
	local max_heap_table_size
	max_heap_table_size=$(sql "SELECT @@max_heap_table_size")
	local tmp_human
	tmp_human=$(numfmt --to=iec --suffix=B "$tmp_table_size" 2>/dev/null || echo "${tmp_table_size} bytes")

	echo "  tmp_table_size:       ${tmp_human}"
	echo "  max_heap_table_size:  $(numfmt --to=iec --suffix=B "$max_heap_table_size" 2>/dev/null || echo "${max_heap_table_size} bytes")"

	# Check disk temp tables
	local disk_tmp created_tmp
	disk_tmp=$(sql "SHOW GLOBAL STATUS LIKE 'Created_tmp_disk_tables'" | awk '{print $2}')
	created_tmp=$(sql "SHOW GLOBAL STATUS LIKE 'Created_tmp_tables'" | awk '{print $2}')
	disk_tmp=${disk_tmp:-0}
	created_tmp=${created_tmp:-1}
	local disk_ratio
	disk_ratio=$(awk "BEGIN {printf \"%.1f\", ($disk_tmp / ($created_tmp + 1)) * 100}")

	echo "  Disk temp tables:     ${disk_tmp}/${created_tmp} (${disk_ratio}%)"
	if (($(echo "$disk_ratio > 25" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${RED}✗ ${disk_ratio}% temp tables go to disk. Increase tmp_table_size and max_heap_table_size.${NC}"
	elif (($(echo "$disk_ratio > 10" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${YELLOW}⚠  ${disk_ratio}% disk ratio. Review queries for missing indexes or large sorts.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy${NC}"
	fi

	# sort_buffer_size
	local sort_buf
	sort_buf=$(sql "SELECT @@sort_buffer_size")
	local sort_buf_human
	sort_buf_human=$(numfmt --to=iec --suffix=B "$sort_buf" 2>/dev/null || echo "${sort_buf} bytes")
	echo "  sort_buffer_size:     ${sort_buf_human}"
	local sort_buf_mb=$((sort_buf / 1048576))
	if ((sort_buf_mb > 4)); then
		echo -e "    ${YELLOW}⚠  Large sort_buffer_size wastes RAM when many connections sort.${NC}"
	fi

	echo ""
}

# ---- Table Open Cache & Definition Cache ------------------------------------
check_table_cache() {
	echo -e "${BOLD}━━━ Table & Definition Cache ━━━${NC}"

	local toc
	toc=$(sql "SELECT @@table_open_cache")
	local tdc
	tdc=$(sql "SELECT @@table_definition_cache")

	echo "  table_open_cache:         ${toc}"
	echo "  table_definition_cache:   ${tdc}"

	local opened_tables
	opened_tables=$(sql "SHOW GLOBAL STATUS LIKE 'Opened_tables'" | awk '{print $2}')
	opened_tables=${opened_tables:-0}

	if ((opened_tables > toc * 2)); then
		echo -e "    ${YELLOW}⚠  ${opened_tables} tables opened. Increase table_open_cache.${NC}"
	fi

	local open_tables
	open_tables=$(sql "SHOW GLOBAL STATUS LIKE 'Open_tables'" | awk '{print $2}')
	open_tables=${open_tables:-0}
	local open_pct
	open_pct=$(awk "BEGIN {printf \"%.0f\", ($open_tables / ($toc + 1)) * 100}")

	echo "  Open tables:              ${open_tables}/${toc} (${open_pct}%)"
	if ((open_pct > 80)); then
		echo -e "    ${YELLOW}⚠  Near cache limit. Increase table_open_cache.${NC}"
	fi

	echo ""
}

# ---- Slow Query Log ---------------------------------------------------------
check_slow_log() {
	echo -e "${BOLD}━━━ Slow Query Log ━━━${NC}"

	local slow_on
	slow_on=$(sql "SELECT @@slow_query_log")
	echo "  Slow Query Log:   ${slow_on}"

	local long_query_time
	long_query_time=$(sql "SELECT @@long_query_time")
	echo "  Long Query Time:  ${long_query_time}s"

	if (($(echo "$long_query_time > 1" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${YELLOW}⚠  Consider lowering to 0.5-1.0s for OLTP workloads.${NC}"
	fi

	local log_queries_not_using_indexes
	log_queries_not_using_indexes=$(sql "SELECT @@log_queries_not_using_indexes")
	echo "  Log No Indexes:   ${log_queries_not_using_indexes}"
	if [[ "$log_queries_not_using_indexes" == "OFF" || "$log_queries_not_using_indexes" == "0" ]]; then
		echo -e "    ${YELLOW}⚠  Enable log_queries_not_using_indexes temporarily to find missing indexes.${NC}"
	fi

	echo ""
}

# ---- Performance Schema -----------------------------------------------------
check_performance_schema() {
	echo -e "${BOLD}━━━ Performance Schema ━━━${NC}"

	local ps_enabled
	ps_enabled=$(sql "SELECT @@performance_schema" 2>/dev/null || echo "OFF")

	if [[ "$ps_enabled" == "ON" || "$ps_enabled" == "1" ]]; then
		echo -e "  ${GREEN}✓ Performance Schema is ON${NC}"

		# Top 5 wait events
		echo ""
		echo "  Top wait events (last snapshot):"
		sql "SELECT EVENT_NAME, COUNT_STAR, SUM_TIMER_WAIT/1000000000000 AS total_sec FROM performance_schema.events_waits_summary_global_by_event_name WHERE COUNT_STAR > 0 ORDER BY SUM_TIMER_WAIT DESC LIMIT 5" 2>/dev/null | while IFS=$'\t' read -r event count wait; do
			printf "    %-50s %10s %8.1fs\n" "${event:0:50}" "$count" "$wait"
		done || echo "    (no wait events recorded)"

		# Statement digest
		echo ""
		echo "  Top query digests (by total time):"
		sql "SELECT LEFT(DIGEST_TEXT, 60) AS query, COUNT_STAR, ROUND(AVG_TIMER_WAIT/1000000000, 1) AS avg_ms FROM performance_schema.events_statements_summary_by_digest WHERE DIGEST_TEXT IS NOT NULL ORDER BY SUM_TIMER_WAIT DESC LIMIT 5" 2>/dev/null | while IFS=$'\t' read -r query count avg_ms; do
			printf "    %-60s calls:%-6s avg:%-8sms\n" "$query" "$count" "$avg_ms"
		done || echo "    (no statement digests)"
	else
		echo -e "  ${RED}✗ Performance Schema is OFF. Enable for query analysis.${NC}"
	fi

	echo ""
}

# ---- Check for Key MySQL 8.0 Features ---------------------------------------
check_8_0_features() {
	echo -e "${BOLD}━━━ MySQL 8.0 Feature Check ━━━${NC}"

	# Invisible indexes
	echo "  Invisible indexes:    Available in 8.0 (for testing drops safely)"

	# Descending indexes
	echo "  Descending indexes:   Available in 8.0"

	# Resource groups
	local rg_enabled
	rg_enabled=$(sql "SELECT @@resource_group_enabled" 2>/dev/null || echo "Not supported")
	echo "  Resource Groups:      ${rg_enabled}"
	if [[ "$rg_enabled" != "ON" && "$rg_enabled" != "1" ]]; then
		echo -e "    ${YELLOW}⚠  Enable resource groups to isolate read vs write workloads.${NC}"
	fi

	# CHECK: Does IO utilization look balanced?
	local io_read_bytes io_write_bytes
	io_read_bytes=$(sql "SHOW GLOBAL STATUS LIKE 'Innodb_data_reads'" 2>/dev/null | awk '{print $2}')
	io_write_bytes=$(sql "SHOW GLOBAL STATUS LIKE 'Innodb_data_writes'" 2>/dev/null | awk '{print $2}')
	echo "  InnoDB IO:           reads=${io_read_bytes:-0}, writes=${io_write_bytes:-0}"

	echo ""
}

# ---- Generate Optimized Config ----------------------------------------------
generate_config() {
	local ibp
	ibp=$(sql "SELECT @@innodb_buffer_pool_size" | head -1 | tr -d '[:space:]')
	local ibp_mb=$((ibp / 1048576))
	local cpu_cores
	cpu_cores=$(nproc 2>/dev/null || echo "4")

	# Calculate optimal buffer pool (60-70% of RAM)
	local optimal_ibp_mb=$((TOTAL_RAM_MB * 65 / 100))
	local optimal_log_size_mb=$((optimal_ibp_mb / 4))
	((optimal_log_size_mb > 4096)) && optimal_log_size_mb=4096
	((optimal_log_size_mb < 512)) && optimal_log_size_mb=512

	# Capacity depends on workload and storage
	local io_capacity=$((TOTAL_RAM_MB > 32000 ? 4000 : (TOTAL_RAM_MB > 16000 ? 3000 : 2000)))

	cat >"$OUTPUT_CNF" <<EOF
# =============================================================================
# MySQL 8.0 Optimized Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Role: ${ROLE}
# Workload:    ${WORKLOAD}
# Total RAM:   ${TOTAL_RAM_MB} MB
# CPU Cores:   ${cpu_cores}
# =============================================================================
#
# This configuration is split into sections. Review each section and adjust
# to your specific hardware, workload, and requirements.
#
# RESTART REQUIRED for: innodb_buffer_pool_size, innodb_log_file_size
# DYNAMIC (no restart): Most other variables can be changed with SET GLOBAL.
# =============================================================================

[mysqld]

# ============================================================================
# 1. INNODB — Buffer Pool & IO
# ============================================================================
# Buffer pool: 65% of RAM for dedicated MySQL. Reduce to 50-55% if MySQL
# shares the VM with other services (web server, app, etc.).
innodb_buffer_pool_size         = $((optimal_ibp_mb))M
innodb_buffer_pool_instances    = $((optimal_ibp_mb / 1024 > 8 ? 8 : (optimal_ibp_mb / 1024 > 0 ? optimal_ibp_mb / 1024 : 1)))

# Log files: ~25% of buffer pool. Larger = better write throughput but
# longer recovery. Max 4GB total across all log files.
innodb_log_file_size            = $((optimal_log_size_mb))M
innodb_log_files_in_group       = 2
innodb_log_buffer_size          = $((optimal_log_size_mb > 256 ? 256 : (optimal_log_size_mb > 64 ? optimal_log_size_mb : 64)))M

# Use O_DIRECT on Linux to avoid OS double-buffering.
# O_DIRECT_NO_FSYNC is faster but only safe on certain filesystems (xfs, ext4).
innodb_flush_method             = O_DIRECT

# Durability: 1 = full ACID (recommended for primary). 2 = fast but risks
# 1 second of data on OS crash. 0 = fastest, only for replicas.
innodb_flush_log_at_trx_commit  = 1

# IO capacity: match your storage.
# - HDD: 200-400
# - SATA SSD: 1000-2000
# - NVMe SSD: 2000-4000
innodb_io_capacity              = ${io_capacity}
innodb_io_capacity_max          = $((io_capacity * 2))

# IO threads: 8-16 for modern SSDs.
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8

# Adaptive hash index: good for read-heavy OLTP. Disable if high contention.
innodb_adaptive_hash_index      = ON
innodb_adaptive_hash_index_parts = $((cpu_cores < 8 ? cpu_cores : 8))

# ============================================================================
# 2. INNODB — Concurrency & Locking
# ============================================================================
innodb_thread_concurrency       = 0                      # Let InnoDB auto-manage
innodb_lock_wait_timeout        = 10                     # 10s timeout for row locks
innodb_deadlock_detect          = ON                     # Detect deadlocks

# ============================================================================
# 3. INNODB — Tablespaces & Undo
# ============================================================================
innodb_file_per_table           = ON                     # One .ibd per table
innodb_autoinc_lock_mode        = 2                      # Interleaved (fastest)
innodb_temp_data_file_path      = ibtmp1:64M:autoextend:max:20G

# ============================================================================
# 4. CONNECTIONS & THREADS
# ============================================================================
max_connections                 = $((TOTAL_RAM_MB / 16 > 500 ? TOTAL_RAM_MB / 16 : 500))
                                                         # Adjust based on connection pool
thread_cache_size               = $((max_connections / 2 < 512 ? max_connections / 2 : 512))
thread_stack                    = 256K
back_log                        = $((max_connections / 5 > 500 ? max_connections / 5 : 500))

# ============================================================================
# 5. SESSION BUFFERS (per-connection memory)
# ============================================================================
# Keep these small — they're per-connection memory!
sort_buffer_size                = 1M
read_buffer_size                = 256K
read_rnd_buffer_size            = 512K
join_buffer_size                = 1M
binlog_cache_size               = 64K

# Set tmp_table_size and max_heap_table_size together.
# 32-64M is good for most OLTP. Increase if Created_tmp_disk_tables % is high.
tmp_table_size                  = 32M
max_heap_table_size             = 32M

# ============================================================================
# 6. TABLE CACHES
# ============================================================================
# ~400 per GB of buffer pool, adjust based on table count
table_open_cache                = $((optimal_ibp_mb / 2 < 10000 ? optimal_ibp_mb / 2 : 10000))
table_definition_cache          = $((table_open_cache / 2 < 2000 ? table_open_cache / 2 : 2000))
table_open_cache_instances      = $((cpu_cores < 16 ? cpu_cores : 16))

# ============================================================================
# 7. QUERY EXECUTION
# ============================================================================
eq_range_index_dive_limit       = 200                    # 8.0 default
range_optimizer_max_mem_size    = 64M
max_length_for_sort_data        = 4096

# ============================================================================
# 8. BINARY LOG & REPLICATION (Primary)
# ============================================================================
# Skip this section on replicas that don't need to be primaries.
log_bin                         = mysql-bin
binlog_format                   = ROW                    # Required for GTID + safety
sync_binlog                     = 1                      # 1 for full durability
binlog_row_image                = FULL
binlog_expire_logs_days         = 7                      # Auto-cleanup after 7 days
max_binlog_size                 = 512M
binlog_cache_size               = 64K
binlog_stmt_cache_size          = 64K

# GTID-based replication
gtid_mode                       = ON
enforce_gtid_consistency        = ON

# Replica-side (primary sections, adjust on replicas)
slave_parallel_type             = LOGICAL_CLOCK
slave_parallel_workers          = 4                      # 4-8 for fast apply
slave_preserve_commit_order     = ON

# ============================================================================
# 9. SLOW QUERY LOG
# ============================================================================
slow_query_log                  = ON
slow_query_log_file             = /var/log/mysql/mysql-slow.log
long_query_time                 = 0.5                    # 500ms for OLTP
log_queries_not_using_indexes   = OFF                    # Toggle ON for index audit
log_slow_admin_statements       = ON
log_slow_replica_statements     = ON
min_examined_row_limit          = 1000                   # Ignore small-table scans

# ============================================================================
# 10. NETWORK & TIMEOUTS
# ============================================================================
connect_timeout                 = 10
wait_timeout                    = 600                    # 10 min idle
interactive_timeout             = 600
net_read_timeout                = 30
net_write_timeout               = 60
max_allowed_packet              = 64M

# ============================================================================
# 11. PERFORMANCE SCHEMA & MONITORING
# ============================================================================
performance_schema              = ON
performance_schema_consumer_events_statements_history_long = ON

# ============================================================================
# 12. SECURITY
# ============================================================================
local_infile                    = OFF
# skip_name_resolve             = ON                     # Uncomment to use IPs only (faster)

# ============================================================================
# 13. RESOURCE GROUPS (MySQL 8.0+)
# ============================================================================
# Isolate read-heavy reporting from OLTP writes.
# After enabling, create resource groups:
#   CREATE RESOURCE GROUP rg_oltp_write TYPE=USER VCPU=0-3 THREAD_PRIORITY=10;
#   CREATE RESOURCE GROUP rg_report_read TYPE=USER VCPU=4-7 THREAD_PRIORITY=5;
resource_group_enabled          = ON

# ============================================================================
# ROLE-SPECIFIC ADJUSTMENTS
# ============================================================================
EOF

	# Role-specific adjustments
	if [[ "$ROLE" == "replica" ]]; then
		cat >>"$OUTPUT_CNF" <<EOF
# REPLICA-SPECIFIC
read_only                       = ON
super_read_only                 = ON
innodb_flush_log_at_trx_commit  = 2                      # Fast, 1s loss acceptable
sync_binlog                     = 0                      # No binlog on replica (unless it chains)
# log_bin                       = OFF                    # Uncomment if no chaining needed
EOF
	fi

	# Workload-specific adjustments
	cat >>"$OUTPUT_CNF" <<EOF

# ============================================================================
# WORKLOAD-SPECIFIC ($WORKLOAD)
# ============================================================================
EOF

	case "$WORKLOAD" in
	read-heavy)
		cat >>"$OUTPUT_CNF" <<EOF
# Read-heavy adjustments
innodb_buffer_pool_size         = $((TOTAL_RAM_MB * 72 / 100))M     # More cache for reads
innodb_adaptive_hash_index      = ON
innodb_read_io_threads          = 12
innodb_write_io_threads         = 4
EOF
		;;
	write-heavy)
		cat >>"$OUTPUT_CNF" <<EOF
# Write-heavy adjustments
innodb_log_file_size            = $((optimal_log_size_mb * 2 > 4096 ? 4096 : optimal_log_size_mb * 2))M
innodb_log_buffer_size          = 256M
innodb_flush_log_at_trx_commit  = 2                      # Trade durability for speed
innodb_io_capacity              = $((io_capacity * 3 / 2))
innodb_io_capacity_max          = $((io_capacity * 3))
innodb_write_io_threads         = 16
innodb_read_io_threads          = 4
innodb_doublewrite              = OFF                    # Disable on ZFS/FusionIO (test carefully!)
sync_binlog                     = 0                      # Batch commits
EOF
		;;
	balanced)
		cat >>"$OUTPUT_CNF" <<EOF
# Balanced workload
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8
innodb_adaptive_hash_index      = ON
EOF
		;;
	oltp | *)
		cat >>"$OUTPUT_CNF" <<EOF
# OLTP adjustments (default — good for web app workloads)
innodb_flush_log_at_trx_commit  = 1                      # Full ACID
sync_binlog                     = 1
innodb_read_io_threads          = 8
innodb_write_io_threads         = 8
innodb_adaptive_hash_index      = ON
EOF
		;;
	esac

	echo -e "${GREEN}${BOLD}✓ Optimized config written to: ${OUTPUT_CNF}${NC}"
}

# ---- Full Report ------------------------------------------------------------
generate_report() {
	{
		echo "==============================================================================="
		echo "  MySQL 8.0 Audit Report"
		echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "  Host: ${MYSQL_HOST}:${MYSQL_PORT}"
		echo "  Role: ${ROLE}"
		echo "  Workload: ${WORKLOAD}"
		echo "==============================================================================="
		echo ""

		# Re-run checks but capture output
		check_version
		check_innodb
		check_connections
		check_replication
		check_query_cache
		check_temp_tables
		check_table_cache
		check_slow_log
		check_performance_schema
		check_8_0_features

		echo "==============================================================================="
		echo "  Recommendations Summary"
		echo "==============================================================================="
		echo ""
		echo "  1. Use connection pooling (ProxySQL, HikariCP, PgBouncer-equivalent)"
		echo "     → Reduces connection churn and per-connection memory pressure."
		echo ""
		echo "  2. Split reads and writes at the application layer"
		echo "     → Primary for writes, replica(s) for reads. Use read-write splitting."
		echo ""
		echo "  3. Implement SQLCommenter-style query tags"
		echo "     → Add /* application=myapp,route=/users/:id,action=show */ to queries"
		echo "     → Enables per-route performance analysis in slow log and Performance Schema."
		echo ""
		echo "  4. Regular index maintenance"
		echo "     → ANALYZE TABLE weekly, check unused indexes monthly."
		echo "     → Use sys.schema_unused_indexes and sys.schema_redundant_indexes."
		echo ""
		echo "  5. Monitor with pt-query-digest or PMM"
		echo "     → Analyze slow query log and Performance Schema digest data."
		echo ""
		echo "  6. Backup strategy"
		echo "     → Percona XtraBackup for hot backups."
		echo "     → Point-in-time recovery via binary logs."
		echo ""

	} >"$OUTPUT_REPORT"

	echo -e "${GREEN}${BOLD}✓ Audit report written to: ${OUTPUT_REPORT}${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║       MySQL 8.0 Audit & Configuration Optimizer             ║${NC}"
echo -e "${CYAN}${BOLD}║       Host: ${MYSQL_HOST}:${MYSQL_PORT}  |  Role: ${ROLE}  |  Workload: ${WORKLOAD}${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

detect_system
check_version
check_innodb
check_connections
check_replication
check_query_cache
check_temp_tables
check_table_cache
check_slow_log
check_performance_schema
check_8_0_features

echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

generate_config
generate_report

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║  Audit Complete                                              ║${NC}"
echo -e "${CYAN}${BOLD}║  Config:   ${OUTPUT_CNF}${NC}"
echo -e "${CYAN}${BOLD}║  Report:   ${OUTPUT_REPORT}${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review ${OUTPUT_CNF} and adjust for your hardware"
echo "  2. Apply dynamic changes: SET GLOBAL <variable> = <value>;"
echo "  3. For static changes (buffer pool, log size), restart MySQL"
echo "  4. Read the companion guide: MYSQL-OPTIMIZATION-GUIDE.md"
echo ""
