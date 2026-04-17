#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# Script: diagnose_high_load.sh
# Purpose: Collect key system metrics to help identify causes of high load.
# Generates timestamped reports for CPU, memory, disk I/O, and network stats.
# Optionally queries Turbonomic recommendations via its REST API.
# ----------------------------------------------------------------------

#--- Configuration -------------------------------------------------------
# Directory where all diagnostic outputs will be stored
OUTPUT_DIR="/var/tmp/load_diagnostics"
mkdir -p "${OUTPUT_DIR}"

# Timestamp used for naming output files
TS="$(date '+%Y%m%d_%H%M%S')"

# Number of samples for vmstat (interval seconds, count)
VMSTAT_INTERVAL=1
VMSTAT_COUNT=10

# Number of iostat reports (interval seconds, count)
IOSTAT_INTERVAL=2
IOSTAT_COUNT=5   # adjust as needed; iostat needs a count when interval is provided

# Turbonomic API settings (optional – fill in if you want automated retrieval)
# Example:
# TURBONOMIC_API_URL="https://turbonomic.example.com/api/v3/recommendations"
# TURBONOMIC_TOKEN="your_api_token_here"
TURBONOMIC_API_URL="${TURBONOMIC_API_URL:-}"
TURBONOMIC_TOKEN="${TURBONOMIC_TOKEN:-}"

#-----------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Starting high‑load diagnostics. Output directory: ${OUTPUT_DIR}"

# 1. Top sorted by CPU (%CPU) – capture a single snapshot in batch mode
TOP_FILE="${OUTPUT_DIR}/top_cpu_${TS}.txt"
log "Collecting top processes by CPU → ${TOP_FILE}"
top -b -o +%CPU -n 1 > "${TOP_FILE}"

# 2. vmstat – monitor memory, swap, and CPU activity over time
VMSTAT_FILE="${OUTPUT_DIR}/vmstat_${TS}.txt"
log "Running vmstat (${VMSTAT_INTERVAL}s interval, ${VMSTAT_COUNT} samples) → ${VMSTAT_FILE}"
vmstat "${VMSTAT_INTERVAL}" "${VMSTAT_COUNT}" > "${VMSTAT_FILE}"

# 3. iostat – detailed disk I/O statistics
IOSTAT_FILE="${OUTPUT_DIR}/iostat_dx_${TS}.txt"
log "Running iostat -dx (${IOSTAT_INTERVAL}s interval, ${IOSTAT_COUNT} samples) → ${IOSTAT_FILE}"
iostat -dx "${IOSTAT_INTERVAL}" "${IOSTAT_COUNT}" > "${IOSTAT_FILE}"

# 4. netstat – interface statistics (RX/TX packets & errors)
NETSTAT_FILE="${OUTPUT_DIR}/netstat_i_${TS}.txt"
log "Gathering network interface statistics → ${NETSTAT_FILE}"
netstat -i > "${NETSTAT_FILE}"

# 5. Turbonomic recommendations (optional)
if [[ -n "${TURBONOMIC_API_URL}" && -n "${TURBONOMIC_TOKEN}" ]]; then
    TURBO_FILE="${OUTPUT_DIR}/turbonomic_recs_${TS}.json"
    log "Fetching Turbonomic recommendations from ${TURBONOMIC_API_URL} → ${TURBO_FILE}"
    curl -sSf -H "Authorization: Bearer ${TURBONOMIC_TOKEN}" \
         -H "Accept: application/json" \
         "${TURBONOMIC_API_URL}" > "${TURBO_FILE}"
else
    log "Turbonomic API variables not set – skipping automated recommendation fetch."
    log "To enable, export TURBONOMIC_API_URL and TURBONOMIC_TOKEN before running this script."
fi

log "Diagnostics collection complete. Review files in ${OUTPUT_DIR}."

exit 0