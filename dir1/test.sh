#!/usr/bin/env bash
#
# Diagnostic & Load‑Testing Script
# ---------------------------------
# Performs a series of automated checks to help pinpoint the root cause of a
# sudden increase in HTTP error responses from an application endpoint.
#
#   1. Log analysis – extracts frequent error patterns.
#   2. Backend health – probes configured health‑check URLs.
#   3. Network inspection – ping/traceroute + TCP port reachability.
#   4. Header comparison – captures request/response headers.
#   5. Code sanity – simple static scans for obvious red flags.
#   6. System resource snapshot – CPU, memory, disk I/O.
#   7. Load test – runs a brief stress test (ApacheBench or wrk).
#   8. Summary – prints next‑steps for developers.
#
# Adjust configuration variables below before execution.

set -euo pipefail

#############################
# Configuration
#############################
# Application endpoint to test
ENDPOINT_URL="https://api.example.com/v1/resource"

# Directory containing log files (plain text)
LOG_DIR="/var/log/myapp"
# Pattern to match log files (e.g., *.log or app_*.log)
LOG_GLOB="*.log"

# Backend services – associative array of name => health‑check URL
declare -A BACKENDS=(
    ["auth"]="http://auth.internal.local/health"
    ["db"]="http://db.internal.local/health"
    ["cache"]="http://cache.internal.local/health"
)

# Number of ICMP packets for basic connectivity test
PING_COUNT=4

# Load‑test parameters (adjust to your environment)
LOADTEST_TOOL=""          # auto‑detect (ab or wrk)
LT_REQUESTS=2000         # total requests
LT_CONCURRENCY=50        # concurrent workers
LT_DURATION="30s"        # used only by wrk

# Output directory for artefacts
OUTDIR="./diagnostic_output"
mkdir -p "$OUTDIR"

#############################
# Helper Functions
#############################
log() {
    local level="$1"; shift
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

die() {
    log "ERROR" "$*"
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

#############################
# 1. Log Analysis
#############################
analyze_logs() {
    log "INFO" "Analyzing logs in ${LOG_DIR}/${LOG_GLOB}"
    local tmpfile="${OUTDIR}/error_patterns.txt"

    # Extract lines that contain typical error markers (HTTP 5xx, "ERROR", etc.)
    # Adjust regexes according to your log format.
    grep -Ei '(\b5[0-9]{2}\b|ERROR|Exception)' "${LOG_DIR}/${LOG_GLOB}" \
        | sed -E 's/^[[:space:]]+//' \
        >"$tmpfile"

    if [[ ! -s "$tmpfile" ]]; then
        log "WARN" "No error entries found in logs."
        return
    fi

    # Summarize most common error snippets (first 120 chars)
    awk '{ line = substr($0,1,120); print line }' "$tmpfile" \
        | sort | uniq -c | sort -rn >"${OUTDIR}/error_summary.txt"

    log "INFO" "Top error patterns written to ${OUTDIR}/error_summary.txt"
}

#############################
# 2. Backend Health Checks
#############################
check_backends() {
    log "INFO" "Checking health of backend services"
    local result_file="${OUTDIR}/backend_health.txt"
    : >"$result_file"

    for name in "${!BACKENDS[@]}"; do
        url="${BACKENDS[$name]}"
        if curl -fs --max-time 5 "$url" >/dev/null; then
            echo "$name OK ($url)" >>"$result_file"
            log "INFO" "Backend $name healthy"
        else
            echo "$name FAIL ($url)" >>"$result_file"
            log "WARN" "Backend $name unreachable"
        fi
    done

    log "INFO" "Backend health report saved to $result_file"
}

#############################
# 3. Network Connectivity
#############################
inspect_network() {
    log "INFO" "Inspecting network connectivity"
    local net_report="${OUTDIR}/network_connectivity.txt"
    : >"$net_report"

    # Ping each backend host
    for name in "${!BACKENDS[@]}"; do
        host=$(echo "${BACKENDS[$name]}" | awk -F[/:] '{print $4}')
        log "DEBUG" "Pinging $host for $name"
        if ping -c "$PING_COUNT" -W 2 "$host" >/dev/null 2>&1; then
            echo "$name ($host): PING OK" >>"$net_report"
        else
            echo "$name ($host): PING FAILED" >>"$net_report"
        fi

        # TCP port check (default to 80/443 based on scheme)
        scheme=$(echo "${BACKENDS[$name]}" | awk -F:// '{print $1}')
        port=$([ "$scheme" == "https" ] && echo 443 || echo 80)
        if command_exists nc; then
            if nc -z -w5 "$host" "$port" >/dev/null 2>&1; then
                echo "$name ($host:$port): PORT OPEN" >>"$net_report"
            else
                echo "$name ($host:$port): PORT CLOSED" >>"$net_report"
            fi
        fi
    done

    # Traceroute to primary endpoint
    if command_exists traceroute; then
        traceroute -n -w 2 "$(awk -F[/:] '{print $4}' <<<"$ENDPOINT_URL")" \
            >"${OUTDIR}/traceroute_to_endpoint.txt" 2>/dev/null || true
    fi

    log "INFO" "Network diagnostics saved to $net_report"
}

#############################
# 4. Request/Response Headers
#############################
capture_headers() {
    log "INFO" "Capturing request and response headers for $ENDPOINT_URL"
    local hdr_file="${OUTDIR}/endpoint_headers.txt"

    # Show request headers sent by curl (-v) and response headers (-D)
    curl -s -D - -o /dev/null -X GET "$ENDPOINT_URL" >"$hdr_file" 2>/dev/null

    log "INFO" "Headers stored at $hdr_file"
}

#############################
# 5. Simple Code Review Scan
#############################
scan_code() {
    log "INFO" "Scanning source tree for common pitfalls"
    local src_dir="/opt/myapp/src"
    local scan_out="${OUTDIR}/code_scan.txt"

    if [[ ! -d "$src_dir" ]]; then
        log "WARN" "Source directory $src_dir not found – skipping code scan"
        return
    fi

    # Look for TODO/FIXME, empty catch blocks, and hard‑coded credentials
    grep -RInE '(TODO|FIXME|BUG|password\s*=|secret\s*=)' "$src_dir" \
        >"$scan_out" || true

    log "INFO" "Code scan results saved to $scan_out"
}

#############################
# 6. System Resource Snapshot
#############################
snapshot_resources() {
    log "INFO" "Collecting system resource metrics"
    local res_file="${OUTDIR}/resource_snapshot.txt"
    {
        echo "=== DATE === $(date)"
        echo "--- CPU ---"
        if command_exists mpstat; then
            mpstat 1 1
        else
            top -bn1 | head -n 5
        fi
        echo "--- MEMORY ---"
        free -h
        echo "--- DISK I/O ---"
        if command_exists iostat; then
            iostat -xz 1 1
        else
            df -hT
        fi
        echo "--- NETWORK STATISTICS ---"
        if command_exists ss; then
            ss -s
        else
            netstat -s
        fi
    } >"$res_file"

    log "INFO" "Resource snapshot written to $res_file"
}

#############################
# 7. Load Testing
#############################
run_load_test() {
    log "INFO" "Running lightweight load test against $ENDPOINT_URL"

    # Detect preferred tool
    if command_exists ab; then
        LOADTEST_TOOL="ab"
    elif command_exists wrk; then
        LOADTEST_TOOL="wrk"
    else
        log "WARN" "Neither 'ab' nor 'wrk' is installed – skipping load test"
        return
    fi

    local lt_out="${OUTDIR}/load_test_result.txt"

    case "$LOADTEST_TOOL" in
        ab)
            ab -n "$LT_REQUESTS" -c "$LT_CONCURRENCY" -s 60 "$ENDPOINT_URL" \
               >"$lt_out" 2>&1
            ;;
        wrk)
            wrk -t"$LT_CONCURRENCY" -c"$LT_CONCURRENCY" -d"$LT_DURATION" "$ENDPOINT_URL" \
               >"$lt_out" 2>&1
            ;;
    esac

    log "INFO" "Load test completed – results in $lt_out"
}

#############################
# 8. Summary & Next Steps
#############################
summarise_findings() {
    cat <<EOF

===== DIAGNOSTIC SUMMARY =====

Logs:           ${OUTDIR}/error_summary.txt
Backends:       ${OUTDIR}/backend_health.txt
Network:        ${OUTDIR}/network_connectivity.txt
Headers:        ${OUTDIR}/endpoint_headers.txt
Code Scan:      ${OUTDIR}/code_scan.txt
Resources:      ${OUTDIR}/resource_snapshot.txt
Load Test:      ${OUTDIR}/load_test_result.txt

Please review the above artifacts and discuss findings with the development team.
Typical next actions:
  • Correlate frequent error patterns with recent deployments.
  • Verify failed backend health checks and restart affected services.
  • Address any header mismatches (e.g., missing auth tokens, wrong Content-Type).
  • Investigate resource saturation indicated in the snapshot.
  • Optimize code paths highlighted by the load test (high latency, errors).

EOF
}

#############################
# Main Execution Flow
#############################
main() {
    log "INFO" "Starting diagnostic routine"
    analyze_logs
    check_backends
    inspect_network
    capture_headers
    scan_code
    snapshot_resources
    run_load_test
    summarise_findings
    log "INFO" "Diagnostic routine finished"
}

main "$@"