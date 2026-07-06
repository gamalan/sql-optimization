#!/usr/bin/env bash
# =============================================================================
# postgresql-audit.sh — PostgreSQL 14+ Audit & Configuration Optimizer
# =============================================================================
# Audits a self-managed PostgreSQL instance (primary or replica) and generates
# an optimized postgresql.conf for OLTP, analytical, or mixed workloads.
#
# Usage:
#   chmod +x postgresql-audit.sh
#   ./postgresql-audit.sh                           # interactive (prompts for creds)
#   ./postgresql-audit.sh -h HOST -U USER -d DB     # non-interactive
#   ./postgresql-audit.sh --help
#
# Output:
#   - Current configuration report (stdout)
#   - postgresql-optimized.conf (generated config)
#   - postgresql-audit-report.txt (full audit report)
# =============================================================================

set -euo pipefail

# ---- Defaults ---------------------------------------------------------------
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-postgres}"
PGPASSWORD="${PGPASSWORD:-}"
OUTPUT_CNF="postgresql-optimized.conf"
OUTPUT_REPORT="postgresql-audit-report.txt"
TOTAL_RAM_MB=""
ROLE="primary"  # primary | replica
WORKLOAD="oltp" # oltp | analytics | balanced | read-heavy

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
postgresql-audit.sh — PostgreSQL Configuration Auditor & Optimizer

USAGE:
  ./postgresql-audit.sh [OPTIONS]

OPTIONS:
  -h, --host HOST      PostgreSQL host (default: 127.0.0.1)
  -p, --port PORT      PostgreSQL port (default: 5432)
  -U, --user USER      PostgreSQL user (default: postgres)
  -d, --dbname DB      Database to connect to (default: postgres)
  -W, --password PASS  PostgreSQL password
  -r, --role ROLE      Server role: primary | replica (default: primary)
  -m, --ram MB         Total system RAM in MB (auto-detected if omitted)
  -w, --workload TYPE  Workload: oltp | analytics | balanced | read-heavy
  --help               Show this help

EXAMPLES:
  ./postgresql-audit.sh
  ./postgresql-audit.sh -h db-primary.internal -U admin -d mydb -r primary
  ./postgresql-audit.sh -h db-replica-1.internal -U admin -d mydb -r replica

EOF
	exit 0
}

# ---- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --host)
		PG_HOST="$2"
		shift 2
		;;
	-p | --port)
		PG_PORT="$2"
		shift 2
		;;
	-U | --user)
		PG_USER="$2"
		shift 2
		;;
	-d | --dbname)
		PG_DB="$2"
		shift 2
		;;
	-W | --password)
		PGPASSWORD="$2"
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

# ---- PostgreSQL Client Check ------------------------------------------------
PSQL_CLI=""
if command -v psql &>/dev/null; then
	PSQL_CLI="psql"
else
	echo -e "${RED}ERROR: psql client not found. Install postgresql-client.${NC}"
	exit 1
fi

# Build connection options
PGOPTS=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -At --pset=footer=off -w)
export PGCONNECT_TIMEOUT=10

if [[ -n "$PGPASSWORD" ]]; then
	export PGPASSWORD="$PGPASSWORD"
fi

# Quick connectivity check
if ! $PSQL_CLI -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -w -c "SELECT 1" &>/dev/null 2>&1; then
	# Try without -w (password may be in .pgpass or trust auth)
	if ! $PSQL_CLI -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null 2>&1; then
		echo -e "${RED}ERROR: Cannot connect to PostgreSQL at ${PG_HOST}:${PG_PORT}/${PG_DB}${NC}"
		echo "Check host, port, credentials, and that the server is running."
		echo "Tip: use .pgpass or set PGPASSWORD for password-based auth."
		exit 1
	fi
	# No -w worked, switch to plain
	PGOPTS=(-h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -At --pset=footer=off)
fi

# ---- Helper: run a query ----------------------------------------------------
sql() {
	$PSQL_CLI "${PGOPTS[@]}" -c "$1" 2>/dev/null || echo "QUERY_ERROR"
}

# ---- Helper: get a setting --------------------------------------------------
get_setting() {
	local name="$1"
	sql "SELECT current_setting('${name}')" 2>/dev/null | head -1
}

# ---- Helper: format bytes to human-readable --------------------------------
bytes_to_human() {
	local bytes="$1"
	if command -v numfmt &>/dev/null; then
		numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes} B"
	else
		# Fallback
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

# ---- System Info ------------------------------------------------------------
detect_system() {
	echo -e "${BOLD}━━━ System Information ━━━${NC}"

	if [[ -z "$TOTAL_RAM_MB" ]]; then
		if [[ -f /proc/meminfo ]]; then
			TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
		elif command -v free &>/dev/null; then
			TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
		else
			# Fallback: estimate from shared_buffers + 30% overhead
			local sb
			sb=$(get_setting shared_buffers)
			if [[ "$sb" =~ ^[0-9]+ ]]; then
				local sb_mb=$((sb / 1048576))
				TOTAL_RAM_MB=$((sb_mb * 100 / 25)) # ~25% is typical, so scale up
			else
				TOTAL_RAM_MB=8192
				echo -e "  ${YELLOW}⚠  Could not detect RAM. Assuming ${TOTAL_RAM_MB} MB. Use -m to override.${NC}"
			fi
		fi
	fi
	echo "  Total RAM:        ${GREEN}${TOTAL_RAM_MB} MB${NC}"

	local cpu_cores
	cpu_cores=$(nproc 2>/dev/null || echo "4")
	export CPU_CORES="$cpu_cores"
	echo "  CPU cores:        ${cpu_cores}"

	echo ""
}

# ---- PostgreSQL Version & Info ----------------------------------------------
check_version() {
	echo -e "${BOLD}━━━ PostgreSQL Version & Info ━━━${NC}"

	local ver
	ver=$(sql "SELECT version()")
	echo "  Version:          ${GREEN}${ver}${NC}"

	local uptime
	uptime=$(sql "SELECT now() - pg_postmaster_start_time()" 2>/dev/null)
	echo "  Uptime:           ${uptime}"

	local data_dir
	data_dir=$(get_setting data_directory)
	echo "  Data Directory:   ${data_dir}"

	local block_size wal_block_size
	block_size=$(get_setting block_size)
	wal_block_size=$(get_setting wal_block_size 2>/dev/null || echo "N/A")
	echo "  Block Size:       ${block_size} bytes"
	echo "  WAL Block Size:   ${wal_block_size}"

	local server_encoding lc_collate
	server_encoding=$(get_setting server_encoding)
	lc_collate=$(get_setting lc_collate)
	echo "  Encoding:         ${server_encoding}"
	echo "  Collation:        ${lc_collate}"

	echo ""
}

# ---- Memory Configuration ---------------------------------------------------
check_memory() {
	echo -e "${BOLD}━━━ Memory Configuration ━━━${NC}"

	# shared_buffers
	local sb
	sb=$(get_setting shared_buffers)
	# Convert to MB: pg settings use kB, 8kB blocks, or unit suffixes
	local sb_bytes
	if [[ "$sb" =~ GB$ ]]; then
		sb_bytes=$(echo "$sb" | sed 's/GB//' | awk '{printf "%d", $1 * 1073741824}')
	elif [[ "$sb" =~ MB$ ]]; then
		sb_bytes=$(echo "$sb" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	elif [[ "$sb" =~ kB$ ]]; then
		sb_bytes=$(echo "$sb" | sed 's/kB//' | awk '{printf "%d", $1 * 1024}')
	else
		# Assume 8kB blocks
		sb_bytes=$((sb * 8192))
	fi
	local sb_mb=$((sb_bytes / 1048576))
	local sb_pct=$((sb_mb * 100 / TOTAL_RAM_MB))

	echo "  shared_buffers:   $(bytes_to_human $sb_bytes) (${sb_pct}% of RAM)"

	local recommended_sb_pct=25
	if ((sb_pct < 15)); then
		echo -e "    ${RED}✗ Very low. Recommend ${recommended_sb_pct}% of RAM (${TOTAL_RAM_MB * recommended_sb_pct / 100} MB).${NC}"
	elif ((sb_pct < 20)); then
		echo -e "    ${YELLOW}⚠  Low. Recommend ${recommended_sb_pct}% of RAM.${NC}"
	elif ((sb_pct > 40)); then
		echo -e "    ${YELLOW}⚠  High (>40%). PostgreSQL also relies on OS page cache.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy range (20-40%)${NC}"
	fi

	# effective_cache_size
	local ecs
	ecs=$(get_setting effective_cache_size)
	local ecs_bytes
	if [[ "$ecs" =~ GB$ ]]; then
		ecs_bytes=$(echo "$ecs" | sed 's/GB//' | awk '{printf "%d", $1 * 1073741824}')
	elif [[ "$ecs" =~ MB$ ]]; then
		ecs_bytes=$(echo "$ecs" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	elif [[ "$ecs" =~ kB$ ]]; then
		ecs_bytes=$(echo "$ecs" | sed 's/kB//' | awk '{printf "%d", $1 * 1024}')
	else
		ecs_bytes=$((ecs * 8192))
	fi
	local ecs_pct=$((ecs_bytes / 1048576 * 100 / TOTAL_RAM_MB))

	echo "  effective_cache:  $(bytes_to_human $ecs_bytes) (${ecs_pct}% of RAM)"

	local recommended_ecs_pct=50
	if ((ecs_pct < 40)); then
		echo -e "    ${YELLOW}⚠  Low. Set to 50-75% of RAM so planner knows OS cache is available.${NC}"
	fi

	# work_mem
	local wm
	wm=$(get_setting work_mem)
	local wm_bytes
	if [[ "$wm" =~ MB$ ]]; then
		wm_bytes=$(echo "$wm" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	elif [[ "$wm" =~ kB$ ]]; then
		wm_bytes=$(echo "$wm" | sed 's/kB//' | awk '{printf "%d", $1 * 1024}')
	else
		wm_bytes=$((wm * 1024))
	fi

	echo "  work_mem:         $(bytes_to_human $wm_bytes)"

	local max_connections
	max_connections=$(get_setting max_connections)
	local work_mem_total=$((wm_bytes / 1048576 * max_connections))
	local work_mem_pct=$((work_mem_total * 100 / TOTAL_RAM_MB))
	echo "  work_mem total:   ${work_mem_total} MB (if all ${max_connections} connections sort, ${work_mem_pct}% of RAM)"

	if ((work_mem_pct > 30)); then
		echo -e "    ${RED}✗ work_mem too high relative to connections. Lower work_mem or max_connections.${NC}"
		echo "      Each sort/hash/aggregate can use work_mem *per operation* (up to work_mem per query node)."
	fi

	local wm_mb=$((wm_bytes / 1048576))
	if ((wm_mb < 4)); then
		echo -e "    ${YELLOW}⚠  Consider 4-16 MB for OLTP, 32-256 MB for analytics.${NC}"
	fi

	# maintenance_work_mem
	local mwm
	mwm=$(get_setting maintenance_work_mem)
	local mwm_bytes
	if [[ "$mwm" =~ GB$ ]]; then
		mwm_bytes=$(echo "$mwm" | sed 's/GB//' | awk '{printf "%d", $1 * 1073741824}')
	elif [[ "$mwm" =~ MB$ ]]; then
		mwm_bytes=$(echo "$mwm" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	elif [[ "$mwm" =~ kB$ ]]; then
		mwm_bytes=$(echo "$mwm" | sed 's/kB//' | awk '{printf "%d", $1 * 1024}')
	else
		mwm_bytes=$((mwm * 1024))
	fi

	echo "  maintenance_work  $(bytes_to_human $mwm_bytes)"

	local mwm_mb=$((mwm_bytes / 1048576))
	local recommended_mwm_mb=$((TOTAL_RAM_MB * 10 / 100 > 2048 ? TOTAL_RAM_MB * 10 / 100 : (TOTAL_RAM_MB * 5 / 100 > 1024 ? TOTAL_RAM_MB * 5 / 100 : 1024)))
	if ((mwm_mb < 256)); then
		echo -e "    ${YELLOW}⚠  Increase to ${recommended_mwm_mb}MB for faster VACUUM/CREATE INDEX.${NC}"
	fi

	# wal_buffers
	local wb
	wb=$(get_setting wal_buffers)
	local wb_bytes
	if [[ "$wb" =~ MB$ ]]; then
		wb_bytes=$(echo "$wb" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	elif [[ "$wb" =~ kB$ ]]; then
		wb_bytes=$(echo "$wb" | sed 's/kB//' | awk '{printf "%d", $1 * 1024}')
	else
		wb_bytes=$((wb * 8192))
	fi

	echo "  wal_buffers:      $(bytes_to_human $wb_bytes)"

	# default: -1 means auto (3% of shared_buffers, capped at 16MB)
	local wb_mb=$((wb_bytes / 1048576))
	local expected_wb_mb=$((sb_mb * 3 / 100 > 16 ? 16 : sb_mb * 3 / 100))
	if [[ "$wb" == "-1" ]]; then
		echo -e "    ${GREEN}✓ Auto (default, ~${expected_wb_mb}MB at current shared_buffers)${NC}"
	elif ((wb_mb < expected_wb_mb)); then
		echo -e "    ${YELLOW}⚠  Consider -1 (auto) or ${expected_wb_mb}MB.${NC}"
	fi

	echo ""
}

# ---- WAL & Checkpoint Configuration -----------------------------------------
check_wal() {
	echo -e "${BOLD}━━━ WAL & Checkpoint Configuration ━━━${NC}"

	# wal_level
	local wal_level
	wal_level=$(get_setting wal_level 2>/dev/null || echo "replica")
	echo "  wal_level:        ${wal_level}"
	case "$wal_level" in
	minimal)
		echo -e "    ${YELLOW}⚠  minimal: no replication support. Use replica or logical.${NC}"
		;;
	replica)
		echo -e "    ${GREEN}✓ replica: supports streaming replication and PITR.${NC}"
		;;
	logical)
		echo -e "    ${GREEN}✓ logical: supports logical replication + decoding.${NC}"
		;;
	esac

	# max_wal_size
	local mws
	mws=$(get_setting max_wal_size)
	local mws_human
	if [[ "$mws" =~ GB$ ]] || [[ "$mws" =~ MB$ ]]; then
		mws_human="$mws"
	else
		mws_human="${mws}MB"
	fi
	echo "  max_wal_size:     ${mws_human}"

	local mws_mb
	if [[ "$mws" =~ GB$ ]]; then
		mws_mb=$(echo "$mws" | sed 's/GB//' | awk '{printf "%d", $1 * 1024}')
	else
		mws_mb=$(echo "$mws" | sed 's/MB//' | awk '{printf "%d", $1}')
	fi
	if ((mws_mb < 1024)); then
		echo -e "    ${YELLOW}⚠  Low for write-heavy workloads. Consider 1-4 GB.${NC}"
	fi

	# min_wal_size
	local min_ws
	min_ws=$(get_setting min_wal_size)
	echo "  min_wal_size:     ${min_ws}"

	# checkpoint_timeout
	local cpt
	cpt=$(get_setting checkpoint_timeout)
	local cpt_sec
	if [[ "$cpt" =~ min$ ]]; then
		cpt_sec=$(echo "$cpt" | sed 's/min//' | awk '{printf "%d", $1 * 60}')
	else
		cpt_sec=$(echo "$cpt" | sed 's/s//' | awk '{printf "%d", $1}')
	fi
	echo "  checkpoint_time:  ${cpt}"

	local cpt_min=$((cpt_sec / 60))
	if ((cpt_min < 5)); then
		echo -e "    ${RED}✗ Too frequent. Set to 10-15 min to reduce checkpoint I/O spikes.${NC}"
	elif ((cpt_min < 10)); then
		echo -e "    ${YELLOW}⚠  Consider 10-15 min for less checkpoint overhead.${NC}"
	else
		echo -e "    ${GREEN}✓ OK${NC}"
	fi

	# checkpoint_completion_target
	local cct
	cct=$(get_setting checkpoint_completion_target)
	echo "  checkpoint_comp:  ${cct}"

	if (($(echo "$cct < 0.7" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${YELLOW}⚠  Increase to 0.9 to spread checkpoint writes and reduce I/O spikes.${NC}"
	fi

	# wal_compression
	local wc
	wc=$(get_setting wal_compression 2>/dev/null || echo "off")
	echo "  wal_compression:  ${wc}"
	if [[ "$wc" == "off" ]] && ((TOTAL_RAM_MB > 8000)); then
		echo -e "    ${YELLOW}⚠  Consider enabling wal_compression to reduce WAL volume (CPU tradeoff).${NC}"
	fi

	# wal_sync_method
	local wsm
	wsm=$(get_setting wal_sync_method)
	echo "  wal_sync_method:  ${wsm}"
	if [[ "$wsm" == "fsync" ]]; then
		echo -e "    ${GREEN}✓ fsync: default, safe.${NC}"
	elif [[ "$wsm" == "fdatasync" ]]; then
		echo -e "    ${YELLOW}⚠  fdatasync: faster but skips metadata sync.${NC}"
	fi

	# synchronous_commit
	local sc
	sc=$(get_setting synchronous_commit)
	echo "  sync_commit:      ${sc}"
	case "$sc" in
	on) echo -e "    ${GREEN}✓ Full durability (recommended for primary).${NC}" ;;
	remote_apply) echo -e "    ${GREEN}✓ Synchronous replication to replica.${NC}" ;;
	local | off) echo -e "    ${YELLOW}⚠  ${sc}: faster but risks data loss.${NC}" ;;
	esac

	# wal_log_hints
	local wlh
	wlh=$(get_setting wal_log_hints 2>/dev/null || echo "off")
	echo "  wal_log_hints:    ${wlh}"
	if [[ "$wlh" == "off" ]]; then
		echo -e "    ${YELLOW}⚠  Enable if using pg_rewind for fast replica failback.${NC}"
	fi

	echo ""
}

# ---- Autovacuum Configuration -----------------------------------------------
check_autovacuum() {
	echo -e "${BOLD}━━━ Autovacuum Configuration ━━━${NC}"

	local av_enabled
	av_enabled=$(get_setting autovacuum 2>/dev/null || echo "on")
	echo "  autovacuum:       ${av_enabled}"
	if [[ "$av_enabled" == "off" ]]; then
		echo -e "    ${RED}✗ Autovacuum is OFF! Transaction ID wraparound risk.${NC}"
		return
	fi

	# Check dead tuples
	local dead_tuples live_tuples dead_pct
	dead_tuples=$(sql "SELECT COALESCE(SUM(n_dead_tup),0) FROM pg_stat_user_tables" 2>/dev/null || echo "0")
	live_tuples=$(sql "SELECT COALESCE(SUM(n_live_tup),0) FROM pg_stat_user_tables" 2>/dev/null || echo "0")
	if ((live_tuples > 0)); then
		dead_pct=$((dead_tuples * 100 / live_tuples))
	else
		dead_pct=0
	fi
	echo "  Dead tuples:      ${dead_tuples}/${live_tuples} (${dead_pct}%)"
	if ((dead_pct > 20)); then
		echo -e "    ${RED}✗ ${dead_pct}% dead tuples. Tune autovacuum or run VACUUM manually.${NC}"
	elif ((dead_pct > 10)); then
		echo -e "    ${YELLOW}⚠  ${dead_pct}% dead tuples. Consider more aggressive autovacuum.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy${NC}"
	fi

	# autovacuum_max_workers
	local av_workers
	av_workers=$(get_setting autovacuum_max_workers)
	echo "  av_max_workers:   ${av_workers}"

	local cpu_cores="${CPU_CORES:-4}"
	local recommended_av=$((cpu_cores / 2 < 3 ? cpu_cores / 2 : (cpu_cores / 2 > 10 ? 10 : cpu_cores / 2)))
	if ((av_workers < 3)); then
		echo -e "    ${YELLOW}⚠  Increase to ${recommended_av} for better vacuum throughput.${NC}"
	fi

	# autovacuum_naptime
	local av_nap
	av_nap=$(get_setting autovacuum_naptime)
	local av_nap_sec
	if [[ "$av_nap" =~ min$ ]]; then
		av_nap_sec=$(echo "$av_nap" | sed 's/min//' | awk '{printf "%d", $1 * 60}')
	else
		av_nap_sec=$(echo "$av_nap" | sed 's/s//' | awk '{printf "%d", $1}')
	fi
	echo "  av_naptime:       ${av_nap}"

	if ((av_nap_sec > 60)); then
		echo -e "    ${YELLOW}⚠  Consider 30s-60s for more frequent vacuum checks.${NC}"
	fi

	# autovacuum_vacuum_scale_factor & threshold
	local av_scale
	av_scale=$(get_setting autovacuum_vacuum_scale_factor)
	local av_thresh
	av_thresh=$(get_setting autovacuum_vacuum_threshold)
	echo "  av_scale_factor:  ${av_scale}"
	echo "  av_threshold:     ${av_thresh}"

	if (($(echo "$av_scale > 0.1" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${YELLOW}⚠  Scale factor ${av_scale} means 10% of table must change. Lower to 0.05 for large tables.${NC}"
	fi

	# autovacuum_vacuum_cost_limit
	local av_cost
	av_cost=$(get_setting autovacuum_vacuum_cost_limit)
	echo "  av_cost_limit:    ${av_cost}"
	if ((av_cost < 200)) && ((TOTAL_RAM_MB > 8000)); then
		echo -e "    ${YELLOW}⚠  Increase to 200-2000 on modern hardware for faster vacuum.${NC}"
	fi

	# autovacuum_vacuum_cost_delay
	local av_cost_delay
	av_cost_delay=$(get_setting autovacuum_vacuum_cost_delay)
	echo "  av_cost_delay:    ${av_cost_delay}ms"
	if ((av_cost_delay > 2)); then
		echo -e "    ${YELLOW}⚠  Reduce to 2ms or 0 for more aggressive vacuum.${NC}"
	fi

	# Track oldest autovacuum / transaction age
	local max_age
	max_age=$(sql "SELECT COALESCE(MAX(age(datfrozenxid)), 0) FROM pg_database" 2>/dev/null || echo "0")
	echo "  Max TXID age:     ${max_age}"
	if ((max_age > 200000000)); then
		echo -e "    ${RED}✗ High transaction age (${max_age}). Autovacuum may be struggling.${NC}"
	elif ((max_age > 100000000)); then
		echo -e "    ${YELLOW}⚠  Transaction age ${max_age}. Monitor autovacuum progress.${NC}"
	else
		echo -e "    ${GREEN}✓ Healthy${NC}"
	fi

	echo ""
}

# ---- Connection Configuration -----------------------------------------------
check_connections() {
	echo -e "${BOLD}━━━ Connection Configuration ━━━${NC}"

	local max_conn
	max_conn=$(get_setting max_connections)
	local superuser_reserved
	superuser_reserved=$(get_setting superuser_reserved_connections)
	local active_conn
	active_conn=$(sql "SELECT count(*) FROM pg_stat_activity WHERE state != 'idle' AND pid != pg_backend_pid()" 2>/dev/null || echo "0")
	local idle_conn
	idle_conn=$(sql "SELECT count(*) FROM pg_stat_activity WHERE state = 'idle' AND pid != pg_backend_pid()" 2>/dev/null || echo "0")

	echo "  max_connections:  ${max_conn}"
	echo "  Active (non-idle): ${active_conn}/${max_conn}"
	echo "  Idle:             ${idle_conn}"
	echo "  Reserved (super): ${superuser_reserved}"

	local total_used=$((active_conn + idle_conn))
	local pct=$((total_used * 100 / (max_conn > 0 ? max_conn : 1)))
	if ((pct > 80)); then
		echo -e "    ${RED}✗ ${pct}% connections used. Use connection pooling (PgBouncer / Pgpool-II).${NC}"
	fi

	# Connection memory estimate
	local wm_bytes
	wm=$(get_setting work_mem)
	if [[ "$wm" =~ MB$ ]]; then
		wm_bytes=$(echo "$wm" | sed 's/MB//' | awk '{printf "%d", $1 * 1048576}')
	else
		wm_bytes=$((wm * 1024))
	fi
	local wm_mb=$((wm_bytes / 1048576))

	# Hash tables, temp buffers also per-query
	local hash_mem_multiplier=256 # rough estimate for hash_mem_multiplier
	local per_conn_risk=$((wm_mb * 4)) # work_mem can be used multiple times per query
	local max_conn_risk=$((per_conn_risk * max_conn))
	local risk_pct=$((max_conn_risk * 100 / TOTAL_RAM_MB))

	echo "  Est conn memory:  ~${per_conn_risk} MB per connection (work_mem × operations)"
	echo "  Max conn memory:  ~${max_conn_risk} MB (${risk_pct}% of RAM)"

	if ((risk_pct > 80)); then
		echo -e "    ${RED}✗ Risk of OOM! Use connection pooling or reduce work_mem.${NC}"
	elif ((risk_pct > 50)); then
		echo -e "    ${YELLOW}⚠  High memory risk under full load.${NC}"
	else
		echo -e "    ${GREEN}✓ OK${NC}"
	fi

	echo ""
}

# ---- Query Planner Configuration --------------------------------------------
check_planner() {
	echo -e "${BOLD}━━━ Query Planner Configuration ━━━${NC}"

	# random_page_cost
	local rpc
	rpc=$(get_setting random_page_cost)
	echo "  random_page_cost: ${rpc}"
	if (($(echo "$rpc > 2.0" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${YELLOW}⚠  High for SSDs. Set to 1.1-1.5 for modern flash storage.${NC}"
	elif (($(echo "$rpc == 4.0" | bc -l 2>/dev/null || echo 0))); then
		echo -e "    ${RED}✗ Default (4.0) is for HDDs. Set to 1.1-1.5 for SSDs.${NC}"
	else
		echo -e "    ${GREEN}✓ Set for SSD${NC}"
	fi

	# effective_io_concurrency
	local eic
	eic=$(get_setting effective_io_concurrency)
	echo "  eff_io_concurrency: ${eic}"
	if ((eic < 2)) && command -v lsblk &>/dev/null; then
		if lsblk -d -o ROTA 2>/dev/null | grep -q "0"; then
			echo -e "    ${YELLOW}⚠  SSD detected but effective_io_concurrency not set. Set to 200 for SSDs.${NC}"
		fi
	fi

	# seq_page_cost
	local spc
	spc=$(get_setting seq_page_cost)
	echo "  seq_page_cost:    ${spc}"

	# cpu_tuple_cost, cpu_index_tuple_cost, cpu_operator_cost
	local ctc citc coc
	ctc=$(get_setting cpu_tuple_cost)
	citc=$(get_setting cpu_index_tuple_cost)
	coc=$(get_setting cpu_operator_cost)
	echo "  cpu_tuple_cost:   ${ctc}"
	echo "  cpu_index_cost:   ${citc}"
	echo "  cpu_operator_cost: ${coc}"

	# default_statistics_target
	local dst
	dst=$(get_setting default_statistics_target)
	echo "  stat_target:      ${dst}"
	if ((dst < 100)); then
		echo -e "    ${YELLOW}⚠  Consider 200-500 for better query plans on large tables.${NC}"
	elif ((dst > 10000)); then
		echo -e "    ${YELLOW}⚠  Very high — increases ANALYZE time. 200-1000 is usually sufficient.${NC}"
	fi

	# jit
	local jit
	jit=$(get_setting jit 2>/dev/null || echo "off")
	echo "  JIT:              ${jit}"
	if [[ "$jit" == "on" ]]; then
		echo -e "    ${YELLOW}⚠  JIT is ON. Good for analytics, but adds overhead for OLTP.${NC}"
	else
		echo -e "    ${GREEN}✓ JIT off: good for OLTP.${NC}"
	fi

	# parallel query settings
	local max_par_workers max_par_workers_per_gather
	max_par_workers=$(get_setting max_parallel_workers)
	max_par_workers_per_gather=$(get_setting max_parallel_workers_per_gather)
	local max_par_maintenance_workers
	max_par_maintenance_workers=$(get_setting max_parallel_maintenance_workers)

	echo "  max_par_workers:  ${max_par_workers}"
	echo "  par_per_gather:   ${max_par_workers_per_gather}"
	echo "  par_maintenance:  ${max_par_maintenance_workers}"

	local cpu_cores="${CPU_CORES:-4}"
	if ((max_par_workers < cpu_cores / 2)); then
		echo -e "    ${YELLOW}⚠  Consider ${cpu_cores}/2 for max_parallel_workers.${NC}"
	fi

	echo ""
}

# ---- Replication Status -----------------------------------------------------
check_replication() {
	echo -e "${BOLD}━━━ Replication Status ━━━${NC}"

	# Check if in recovery (replica)
	local in_recovery
	in_recovery=$(sql "SELECT pg_is_in_recovery()" 2>/dev/null || echo "ERROR")
	if [[ "$in_recovery" == "QUERY_ERROR" || "$in_recovery" == "ERROR" ]]; then
		echo "  ${YELLOW}Could not determine replication state.${NC}"
		echo ""
		return
	fi

	if [[ "$in_recovery" == "t" ]]; then
		# This is a replica
		echo "  Role:             ${GREEN}REPLICA${NC}"

		# Replay lag
		local replay_lag
		replay_lag=$(sql "SELECT COALESCE(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp()), 0)::int" 2>/dev/null || echo "0")
		echo "  Replay lag:       ${replay_lag}s"
		if ((replay_lag > 10)); then
			echo -e "    ${RED}✗ High replay lag: ${replay_lag}s${NC}"
		elif ((replay_lag > 1)); then
			echo -e "    ${YELLOW}⚠  Replay lag: ${replay_lag}s${NC}"
		else
			echo -e "    ${GREEN}✓ Up to date${NC}"
		fi

		# WAL receiver status
		local wal_recv_pid wal_recv_status
		wal_recv_pid=$(sql "SELECT pid FROM pg_stat_wal_receiver" 2>/dev/null || echo "")
		if [[ -n "$wal_recv_pid" ]]; then
			echo -e "  WAL Receiver:     ${GREEN}Running (PID ${wal_recv_pid})${NC}"
		else
			echo -e "  ${RED}✗ WAL receiver not running!${NC}"
		fi

		# Check hot_standby
		local hot_standby
		hot_standby=$(get_setting hot_standby 2>/dev/null || echo "off")
		echo "  hot_standby:      ${hot_standby}"
		if [[ "$hot_standby" == "off" ]]; then
			echo -e "    ${YELLOW}⚠  hot_standby=off means replica cannot serve read queries.${NC}"
		fi

	else
		# This is a primary
		echo "  Role:             ${GREEN}PRIMARY${NC}"

		# List replicas
		local replica_count
		replica_count=$(sql "SELECT count(*) FROM pg_stat_replication" 2>/dev/null || echo "0")
		echo "  Replicas:         ${replica_count}"

		if ((replica_count > 0)); then
			sql "SELECT application_name, client_addr, state, sync_state, 
				EXTRACT(EPOCH FROM (now() - replay_lag))::int AS lag_sec,
				pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
				FROM pg_stat_replication ORDER BY replay_lag DESC NULLS LAST" 2>/dev/null | while IFS='|' read -r app addr state sync lag_sec lag_bytes; do
				printf "    %-20s %-15s %-10s %-10s %5ss  %10s bytes\n" "$app" "$addr" "$state" "$sync" "$lag_sec" "$lag_bytes"
			done || echo "    (no replica details)"
		fi

		# WAL archiving
		local archive_mode archive_cmd
		archive_mode=$(get_setting archive_mode 2>/dev/null || echo "off")
		archive_cmd=$(get_setting archive_command 2>/dev/null || echo "(none)")
		echo "  archive_mode:     ${archive_mode}"
		echo "  archive_command:  ${archive_cmd}"
		if [[ "$archive_mode" == "off" ]]; then
			echo -e "    ${YELLOW}⚠  Enable archive_mode for PITR backups.${NC}"
		fi

		# max_wal_senders
		local wal_senders
		wal_senders=$(get_setting max_wal_senders)
		echo "  max_wal_senders:  ${wal_senders}"
		local wal_senders_used
		wal_senders_used=$(sql "SELECT count(*) FROM pg_stat_replication" 2>/dev/null || echo "0")
		if ((wal_senders_used >= wal_senders)); then
			echo -e "    ${RED}✗ All WAL senders used (${wal_senders_used}/${wal_senders}). Increase max_wal_senders.${NC}"
		fi

		# max_replication_slots
		local repl_slots
		repl_slots=$(get_setting max_replication_slots)
		echo "  max_repl_slots:   ${repl_slots}"
		local slots_used
		slots_used=$(sql "SELECT count(*) FROM pg_replication_slots" 2>/dev/null || echo "0")
		if ((slots_used >= repl_slots)); then
			echo -e "    ${RED}✗ All replication slots used (${slots_used}/${repl_slots}). Increase max_replication_slots.${NC}"
		fi
	fi

	echo ""
}

# ---- Logging & Monitoring ---------------------------------------------------
check_logging() {
	echo -e "${BOLD}━━━ Logging & Monitoring ━━━${NC}"

	# log settings
	local log_dest log_min_dur log_autovacuum
	log_dest=$(get_setting log_destination)
	local log_collector
	log_collector=$(get_setting logging_collector 2>/dev/null || echo "off")

	echo "  log_destination:  ${log_dest}"
	echo "  logging_collector: ${log_collector}"

	# log_min_duration_statement
	log_min_dur=$(get_setting log_min_duration_statement)
	local log_min_dur_ms
	if [[ "$log_min_dur" =~ min$ ]]; then
		log_min_dur_ms=$(echo "$log_min_dur" | sed 's/min//' | awk '{printf "%d", $1 * 60000}')
	elif [[ "$log_min_dur" =~ s$ ]]; then
		log_min_dur_ms=$(echo "$log_min_dur" | sed 's/s//' | awk '{printf "%d", $1 * 1000}')
	else
		log_min_dur_ms=$(echo "$log_min_dur" | sed 's/ms//' | awk '{printf "%d", $1}')
	fi
	echo "  log_min_duration: ${log_min_dur}"
	if [[ "$log_min_dur" == "-1" ]]; then
		echo -e "    ${RED}✗ Slow query logging is OFF. Set to 500ms or 1000ms.${NC}"
	elif ((log_min_dur_ms > 2000)); then
		echo -e "    ${YELLOW}⚠  Threshold is high (${log_min_dur_ms}ms). Lower to 500ms for OLTP.${NC}"
	else
		echo -e "    ${GREEN}✓ Logging slow queries${NC}"
	fi

	# log_autovacuum_min_duration
	log_autovacuum=$(get_setting log_autovacuum_min_duration 2>/dev/null || echo "-1")
	echo "  log_autovacuum:   ${log_autovacuum}"
	if [[ "$log_autovacuum" == "-1" ]]; then
		echo -e "    ${YELLOW}⚠  Set to 0 to log all autovacuum activity (or 1000ms for long vacuums).${NC}"
	fi

	# log_checkpoints
	local log_checkpoints
	log_checkpoints=$(get_setting log_checkpoints 2>/dev/null || echo "off")
	echo "  log_checkpoints:  ${log_checkpoints}"
	if [[ "$log_checkpoints" == "off" ]]; then
		echo -e "    ${YELLOW}⚠  Enable log_checkpoints to monitor checkpoint frequency and duration.${NC}"
	fi

	# log_lock_waits
	local log_lock_waits
	log_lock_waits=$(get_setting log_lock_waits)
	echo "  log_lock_waits:   ${log_lock_waits}"
	if [[ "$log_lock_waits" == "off" ]]; then
		echo -e "    ${YELLOW}⚠  Enable log_lock_waits to detect blocked queries.${NC}"
	fi

	# log_temp_files
	local log_temp_files
	log_temp_files=$(get_setting log_temp_files)
	echo "  log_temp_files:   ${log_temp_files}"
	if [[ "$log_temp_files" == "-1" ]]; then
		echo -e "    ${YELLOW}⚠  Set to 32MB (32768) to log queries spilling to disk.${NC}"
	fi

	# pg_stat_statements
	echo ""
	echo "  Extensions:"

	local pgss_installed
	pgss_installed=$(sql "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'" 2>/dev/null || echo "0")
	if ((pgss_installed > 0)); then
		# Top queries by total time
		echo -e "  ${GREEN}✓ pg_stat_statements installed${NC}"
		echo "  Top 5 queries (by mean time):"
		sql "SELECT LEFT(query, 60) AS q,
			calls,
			round(mean_exec_time::numeric, 1) AS mean_ms
			FROM pg_stat_statements
			WHERE query NOT LIKE '%pg_stat%'
			ORDER BY mean_exec_time DESC LIMIT 5" 2>/dev/null | while IFS='|' read -r q calls mean_ms; do
			printf "    %-60s calls:%-8s mean:%-8sms\n" "$q" "$calls" "$mean_ms"
		done || echo "    (could not query pg_stat_statements)"
	else
		echo -e "  ${RED}✗ pg_stat_statements NOT installed. Run: CREATE EXTENSION pg_stat_statements;${NC}"
	fi

	# auto_explain
	local ae_installed
	ae_installed=$(sql "SELECT count(*) FROM pg_extension WHERE extname = 'auto_explain'" 2>/dev/null || echo "0")
	if ((ae_installed > 0)); then
		echo -e "  ${GREEN}✓ auto_explain installed${NC}"
	else
		echo -e "  ${YELLOW}⚠  auto_explain not installed. Useful for ad-hoc EXPLAIN on slow queries.${NC}"
	fi

	echo ""
}

# ---- Database & Table Statistics --------------------------------------------
check_db_stats() {
	echo -e "${BOLD}━━━ Database & Table Statistics ━━━${NC}"

	# Database sizes
	echo "  Database sizes:"
	sql "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
		FROM pg_database WHERE datname NOT IN ('template0','template1')
		ORDER BY pg_database_size(datname) DESC" 2>/dev/null | while IFS='|' read -r db size; do
		printf "    %-30s %s\n" "$db" "$size"
	done || echo "    (could not query)"

	# Table count
	local table_count
	table_count=$(sql "SELECT count(*) FROM pg_stat_user_tables" 2>/dev/null || echo "0")
	echo ""
	echo "  User tables:      ${table_count}"

	# Tables with no indexes (potential scans)
	local no_idx
	no_idx=$(sql "SELECT count(*) FROM pg_stat_user_tables t WHERE t.seq_scan > 0
		AND NOT EXISTS (SELECT 1 FROM pg_indexes i WHERE i.tablename = t.relname AND i.schemaname = t.schemaname AND indexname NOT LIKE '%_pkey')" 2>/dev/null || echo "0")
	echo "  Tables w/o index: ${no_idx}"
	if ((no_idx > 0)); then
		echo -e "    ${YELLOW}⚠  Tables without indexes may cause full scans.${NC}"
	fi

	# Unused indexes
	local unused_idx
	unused_idx=$(sql "SELECT count(*) FROM pg_stat_user_indexes WHERE idx_scan = 0 AND indexrelname NOT LIKE '%_pkey' AND indexrelname NOT LIKE '%_excl'" 2>/dev/null || echo "0")
	echo "  Unused indexes:   ${unused_idx}"
	if ((unused_idx > 5)); then
		echo -e "    ${YELLOW}⚠  ${unused_idx} unused indexes — they waste write performance and disk space.${NC}"
	fi

	# Cache hit ratio
	local heap_read heap_hit idx_read idx_hit
	heap_read=$(sql "SELECT COALESCE(SUM(heap_blks_read),0) FROM pg_statio_user_tables" 2>/dev/null || echo "0")
	heap_hit=$(sql "SELECT COALESCE(SUM(heap_blks_hit),0) FROM pg_statio_user_tables" 2>/dev/null || echo "0")
	idx_read=$(sql "SELECT COALESCE(SUM(idx_blks_read),0) FROM pg_statio_user_tables" 2>/dev/null || echo "0")
	idx_hit=$(sql "SELECT COALESCE(SUM(idx_blks_hit),0) FROM pg_statio_user_tables" 2>/dev/null || echo "0")

	local heap_total=$((heap_read + heap_hit))
	local idx_total=$((idx_read + idx_hit))
	local heap_ratio=$((heap_total > 0 ? heap_hit * 100 / heap_total : 0))
	local idx_ratio=$((idx_total > 0 ? idx_hit * 100 / idx_total : 0))

	echo ""
	echo "  Cache hit ratios:"
	echo "    Heap:           ${heap_ratio}%"
	echo "    Index:          ${idx_ratio}%"

	if ((heap_ratio < 95)); then
		echo -e "    ${YELLOW}⚠  Heap cache hit below 95%. Consider increasing shared_buffers.${NC}"
	fi
	if ((idx_ratio < 99)); then
		echo -e "    ${YELLOW}⚠  Index cache hit below 99%. Increase shared_buffers.${NC}"
	fi

	# Top bloated tables
	echo ""
	echo "  Top 5 tables by dead tuples:"
	sql "SELECT relname, n_live_tup, n_dead_tup,
		CASE WHEN n_live_tup > 0 THEN round(n_dead_tup::numeric / n_live_tup * 100, 1) ELSE 0 END AS dead_pct
		FROM pg_stat_user_tables
		ORDER BY n_dead_tup DESC LIMIT 5" 2>/dev/null | while IFS='|' read -r tbl live dead pct; do
		printf "    %-30s live:%-8s dead:%-8s %s%%\n" "$tbl" "$live" "$dead" "$pct"
	done || echo "    (could not query)"

	echo ""
}

# ---- Index Analysis ---------------------------------------------------------
check_indexes() {
	echo -e "${BOLD}━━━ Index Analysis ━━━${NC}"

	# Duplicate indexes
	local dup_count
	dup_count=$(sql "SELECT count(*) FROM (
		SELECT indrelid::regclass AS tbl, array_agg(indexrelid::regclass) AS idxs
		FROM pg_index GROUP BY (indrelid::regclass::text || ':' || indkey::text)
		HAVING count(*) > 1) s" 2>/dev/null || echo "0")
	echo "  Duplicate indexes: ${dup_count}"
	if ((dup_count > 0)); then
		echo -e "    ${YELLOW}⚠  Duplicate indexes waste write I/O and disk space.${NC}"
	fi

	# Invalid indexes
	local invalid_count
	invalid_count=$(sql "SELECT count(*) FROM pg_index WHERE indisvalid = false" 2>/dev/null || echo "0")
	echo "  Invalid indexes:  ${invalid_count}"
	if ((invalid_count > 0)); then
		echo -e "    ${RED}✗ ${invalid_count} invalid indexes. REINDEX or drop them.${NC}"
	fi

	# Index scan ratio
	local total_scans idx_scans
	total_scans=$(sql "SELECT COALESCE(SUM(seq_scan + idx_scan),0) FROM pg_stat_user_tables" 2>/dev/null || echo "1")
	idx_scans=$(sql "SELECT COALESCE(SUM(idx_scan),0) FROM pg_stat_user_tables" 2>/dev/null || echo "0")
	local scan_ratio=$((idx_scans * 100 / (total_scans > 0 ? total_scans : 1)))
	echo "  Index scan ratio: ${scan_ratio}%"
	if ((scan_ratio < 80)); then
		echo -e "    ${YELLOW}⚠  ${scan_ratio}% index scans — might need better indexes.${NC}"
	else
		echo -e "    ${GREEN}✓ Good${NC}"
	fi

	echo ""
}

# ---- Generate Optimized Config ----------------------------------------------
generate_config() {
	local cpu_cores="${CPU_CORES:-4}"

	# Memory calculations
	local optimal_sb_mb=$((TOTAL_RAM_MB * 25 / 100))
	local optimal_ecs_mb=$((TOTAL_RAM_MB * 50 / 100))
	local optimal_mwm_mb=$((TOTAL_RAM_MB * 5 / 100 > 1024 ? TOTAL_RAM_MB * 5 / 100 : 1024))
	((optimal_mwm_mb > 2048)) && optimal_mwm_mb=2048
	local optimal_wm_mb=4
	if [[ "$WORKLOAD" == "analytics" ]]; then
		optimal_wm_mb=32
	elif [[ "$WORKLOAD" == "balanced" ]]; then
		optimal_wm_mb=8
	fi
	((optimal_wm_mb > TOTAL_RAM_MB / (4 * 100))) && optimal_wm_mb=$((TOTAL_RAM_MB / (4 * 100)))

	local max_conn_est=$((TOTAL_RAM_MB / 8 > 500 ? TOTAL_RAM_MB / 8 : 500))
	local wal_senders_est=$((cpu_cores < 8 ? cpu_cores : 8))
	local av_workers=$((cpu_cores / 2 < 3 ? cpu_cores / 2 : (cpu_cores / 2 > 10 ? 10 : cpu_cores / 2)))
	local max_par_workers=$((cpu_cores / 2 < 2 ? 2 : cpu_cores / 2))
	local max_par_per_gather=$((cpu_cores / 4 < 1 ? 1 : cpu_cores / 4))

	local ssd_detected=false
	if command -v lsblk &>/dev/null; then
		if lsblk -d -o ROTA 2>/dev/null | grep -q "0"; then
			ssd_detected=true
		fi
	fi

	local rpc_val="4.0"
	local eic_val="0"
	if [[ "$ssd_detected" == true ]]; then
		rpc_val="1.1"
		eic_val="200"
	fi

	cat >"$OUTPUT_CNF" <<PGEOF
# =============================================================================
# PostgreSQL Optimized Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Server Role: ${ROLE}
# Workload:    ${WORKLOAD}
# Total RAM:   ${TOTAL_RAM_MB} MB
# CPU Cores:   ${cpu_cores}
# =============================================================================
#
# Apply: cp postgresql-optimized.conf \$PGDATA/postgresql.conf
# Then:   pg_ctl reload   (for most settings)
# Or:     pg_ctl restart  (for settings requiring restart)
# =============================================================================

# ============================================================================
# 1. MEMORY
# ============================================================================
# Shared buffers: 25% of RAM for dedicated PostgreSQL. PostgreSQL relies
# heavily on the OS page cache, so do NOT allocate more than 40%.
shared_buffers = ${optimal_sb_mb}MB

# OS page cache hint for the query planner. Set to 50-75% of total RAM.
effective_cache_size = ${optimal_ecs_mb}MB

# Per-operation memory for sorts, hashes, and aggregates.
# Keep this modest for OLTP; increase for analytics.
# WARNING: a single query can use work_mem multiple times (per sort/hash node).
work_mem = ${optimal_wm_mb}MB

# Memory for VACUUM, CREATE INDEX, ALTER TABLE operations.
maintenance_work_mem = ${optimal_mwm_mb}MB

# WAL buffers. -1 = auto (3% of shared_buffers, capped at 16MB).
# Only override for write-heavy workloads.
wal_buffers = -1

# ============================================================================
# 2. CONNECTIONS
# ============================================================================
# Use connection pooling (PgBouncer) to handle more clients with fewer
# PostgreSQL connections. Each connection consumes ~2-10 MB + work_mem.
max_connections = ${max_conn_est}
superuser_reserved_connections = 3

# ============================================================================
# 3. WAL & CHECKPOINTS
# ============================================================================
# Pin to replica for streaming replication; logical for CDC/replication tools.
wal_level = replica

# Max total WAL size before a checkpoint is triggered. Larger = less frequent
# checkpoints = less I/O spikes but longer recovery. 1-4 GB is good for OLTP.
max_wal_size = 4GB
min_wal_size = 1GB

# Checkpoint frequency: 10-15 minutes with 0.9 completion target spreads I/O.
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# WAL compression: reduces WAL volume at CPU cost. Enable for write-heavy.
# wal_compression = on

# Full durability. Set to 'off' or 'local' for replicas / write-heavy if
# losing a small window of data on crash is acceptable.
synchronous_commit = on

# Enable WAL log hints for pg_rewind (fast replica failback).
wal_log_hints = on

# ============================================================================
# 4. AUTOVACUUM
# ============================================================================
# Autovacuum is CRITICAL for PostgreSQL health — it prevents transaction ID
# wraparound and reclaims dead tuple space.
autovacuum = on
autovacuum_max_workers = ${av_workers}
autovacuum_naptime = 30s

# Trigger VACUUM when 5% of rows change (more aggressive than default 10%).
# For large tables (100M+ rows), set per-table: ALTER TABLE t SET (autovacuum_vacuum_scale_factor = 0.01);
autovacuum_vacuum_scale_factor = 0.05
autovacuum_vacuum_threshold = 50

# Cost-based vacuum throttling. Increase cost limit on modern hardware.
autovacuum_vacuum_cost_limit = $((TOTAL_RAM_MB > 16000 ? 2000 : (TOTAL_RAM_MB > 8000 ? 1000 : 200)))
autovacuum_vacuum_cost_delay = 2ms

# Analyze threshold: keep table statistics current.
autovacuum_analyze_scale_factor = 0.05
autovacuum_analyze_threshold = 50

# ============================================================================
# 5. QUERY PLANNER
# ============================================================================
# Cost model for the query planner. These settings tell the planner how
# expensive different operations are relative to each other.
random_page_cost = ${rpc_val}          # 1.1 for SSDs, 4.0 for HDDs
seq_page_cost = 1.0                   # Baseline
cpu_tuple_cost = 0.01
cpu_index_tuple_cost = 0.005
cpu_operator_cost = 0.0025

# Effective I/O concurrency: how many concurrent I/O operations the storage
# can handle. 200 for SSDs, 2 for HDDs.
effective_io_concurrency = ${eic_val}

# Statistics granularity: 200-500 gives the planner more samples.
default_statistics_target = 200

# JIT compilation. Good for analytics queries, adds overhead for OLTP.
jit = off                            # off for OLTP, on for analytics

# ============================================================================
# 6. PARALLEL QUERY
# ============================================================================
max_parallel_workers = ${max_par_workers}
max_parallel_workers_per_gather = ${max_par_per_gather}
max_parallel_maintenance_workers = $((cpu_cores / 4 < 1 ? 1 : cpu_cores / 4))

# Minimum table size for parallel scans. 8MB default; increase for analytics.
# min_parallel_table_scan_size = 8MB
# min_parallel_index_scan_size = 512kB

# ============================================================================
# 7. LOGGING
# ============================================================================
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%a.log'      # Daily rotation
log_truncate_on_rotation = on
log_rotation_age = 1d
log_rotation_size = 0

# Log queries running longer than 500ms (good for OLTP; increase for analytics).
log_min_duration_statement = 500ms

# Log these important events.
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 32MB                  # Log queries that spill > 32MB to disk

# Log autovacuum activity taking > 1s.
log_autovacuum_min_duration = 1000ms

# Log statement with duration and query text.
log_line_prefix = '%t [%p]: user=%u,db=%d,app=%a,client=%h '

# ============================================================================
# 8. REPLICATION (Primary-side)
# ============================================================================
# Skip or adjust on replicas.
wal_level = replica
max_wal_senders = ${wal_senders_est}
max_replication_slots = ${wal_senders_est}
wal_keep_size = 1GB                    # Keep WAL for replicas

# For synchronous replication, uncomment and set application_name:
# synchronous_standby_names = 'replica1,replica2'

# ============================================================================
# 9. EXTENSIONS (run after config reload)
# ============================================================================
# These require CREATE EXTENSION in each database.
# shared_preload_libraries = 'pg_stat_statements,auto_explain'
# pg_stat_statements.track = all
# auto_explain.log_min_duration = '500ms'
# auto_explain.log_analyze = on

# ============================================================================
# ROLE-SPECIFIC ADJUSTMENTS
# ============================================================================
PGEOF

	if [[ "$ROLE" == "replica" ]]; then
		cat >>"$OUTPUT_CNF" <<PGEOF
# REPLICA-SPECIFIC
hot_standby = on
hot_standby_feedback = on              # Prevent query conflicts on replica

# Lower durability on replicas (WAL comes from primary anyway).
synchronous_commit = off
# Disable WAL archiving on replica (usually).
# archive_mode = off
PGEOF
	fi

	# Workload-specific adjustments
	cat >>"$OUTPUT_CNF" <<PGEOF

# ============================================================================
# WORKLOAD-SPECIFIC ($WORKLOAD)
# ============================================================================
PGEOF

	case "$WORKLOAD" in
	analytics)
		cat >>"$OUTPUT_CNF" <<PGEOF
# Analytics: larger work_mem, parallel query, JIT.
work_mem = $((optimal_wm_mb * 4 > TOTAL_RAM_MB / (max_conn_est * 2) ? TOTAL_RAM_MB / (max_conn_est * 2) : optimal_wm_mb * 4))MB
maintenance_work_mem = $((optimal_mwm_mb * 2))MB
shared_buffers = $((TOTAL_RAM_MB * 15 / 100))MB    # Less buffer, more OS cache for scans
effective_cache_size = $((TOTAL_RAM_MB * 70 / 100))MB
jit = on
max_parallel_workers = ${cpu_cores}
max_parallel_workers_per_gather = $((cpu_cores / 2 > 0 ? cpu_cores / 2 : 1))
random_page_cost = 1.1
default_statistics_target = 500
checkpoint_timeout = 30min
max_wal_size = 8GB
PGEOF
		;;
	read-heavy)
		cat >>"$OUTPUT_CNF" <<PGEOF
# Read-heavy: bigger buffer cache, lower write overhead.
shared_buffers = $((TOTAL_RAM_MB * 35 / 100))MB
effective_cache_size = $((TOTAL_RAM_MB * 65 / 100))MB
checkpoint_timeout = 30min
autovacuum_vacuum_cost_limit = 500
PGEOF
		;;
	balanced)
		cat >>"$OUTPUT_CNF" <<PGEOF
# Balanced: moderate settings for mixed read/write.
shared_buffers = $((TOTAL_RAM_MB * 25 / 100))MB
effective_cache_size = $((TOTAL_RAM_MB * 50 / 100))MB
checkpoint_timeout = 15min
autovacuum_vacuum_cost_limit = 1000
PGEOF
		;;
	oltp | *)
		cat >>"$OUTPUT_CNF" <<PGEOF
# OLTP: fast transactions, small work_mem, frequent checkpoints.
shared_buffers = $((TOTAL_RAM_MB * 25 / 100))MB
effective_cache_size = $((TOTAL_RAM_MB * 50 / 100))MB
work_mem = 4MB
synchronous_commit = on
checkpoint_timeout = 10min
autovacuum_vacuum_cost_limit = 1000
jit = off
PGEOF
		;;
	esac

	echo -e "${GREEN}${BOLD}✓ Optimized config written to: ${OUTPUT_CNF}${NC}"
}

# ---- Full Report ------------------------------------------------------------
generate_report() {
	{
		echo "==============================================================================="
		echo "  PostgreSQL Configuration Audit Report"
		echo "  Generated: $(date '+%Y-%m-%d %H:%M:%S')"
		echo "  Host: ${PG_HOST}:${PG_PORT}/${PG_DB}"
		echo "  Role: ${ROLE}"
		echo "  Workload: ${WORKLOAD}"
		echo "==============================================================================="
		echo ""

		check_version
		check_memory
		check_wal
		check_autovacuum
		check_connections
		check_planner
		check_replication
		check_logging
		check_db_stats
		check_indexes

		echo "==============================================================================="
		echo "  Recommendations Summary"
		echo "==============================================================================="
		echo ""
		echo "  1. Use connection pooling (PgBouncer or Pgpool-II)"
		echo "     → Reduces connection overhead and per-connection memory."
		echo "     → Use transaction mode for web apps (fastest)."
		echo ""
		echo "  2. Install and configure pg_stat_statements"
		echo "     → Identifies slow queries, call frequency, and execution time."
		echo "     → Run: CREATE EXTENSION pg_stat_statements;"
		echo ""
		echo "  3. Tune autovacuum for your workload"
		echo "     → Aggressive settings for high-update tables."
		echo "     → Monitor with: SELECT * FROM pg_stat_progress_vacuum;"
		echo ""
		echo "  4. Set up WAL archiving for PITR backups"
		echo "     → Use pgBackRest, Barman, or WAL-G for continuous archiving."
		echo ""
		echo "  5. Monitor indexes regularly"
		echo "     → Find unused: SELECT * FROM pg_stat_user_indexes WHERE idx_scan = 0;"
		echo "     → Find duplicates: Check indexes with same column sets."
		echo ""
		echo "  6. Regular VACUUM and ANALYZE"
		echo "     → VACUUM ANALYZE on busy tables weekly (or enable aggressive autovacuum)."
		echo "     → REINDEX concurrently on bloated indexes during low-usage windows."
		echo ""
		echo "  7. Use read replicas to offload reporting/analytics queries"
		echo "     → Route read-heavy queries to replicas via app-level splitting."
		echo ""
		echo "  8. Set random_page_cost correctly for your storage"
		echo "     → 1.1 for NVMe/SSD, 1.5-2.0 for SATA SSD, 4.0 for HDD."
		echo ""
	} >"$OUTPUT_REPORT"

	echo -e "${GREEN}${BOLD}✓ Audit report written to: ${OUTPUT_REPORT}${NC}"
}

# =============================================================================
# MAIN
# =============================================================================
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║    PostgreSQL Audit & Configuration Optimizer               ║${NC}"
echo -e "${CYAN}${BOLD}║    Host: ${PG_HOST}:${PG_PORT}/${PG_DB}  |  Role: ${ROLE}  |  Workload: ${WORKLOAD}${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

detect_system
check_version
check_memory
check_wal
check_autovacuum
check_connections
check_planner
check_replication
check_logging
check_db_stats
check_indexes

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
echo "  2. Apply: cp ${OUTPUT_CNF} \$PGDATA/postgresql.conf"
echo "  3. Reload: pg_ctl reload (or SELECT pg_reload_conf();)"
echo "  4. Restart for: shared_buffers, max_connections, wal_level changes"
echo ""
