#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# High System Load Investigation Script
# Detects when load average exceeds 2 × CPU core count and gathers
# diagnostic data to aid troubleshooting.
#
# Author: Automated Generation
# Version: 1.0
# ----------------------------------------------------------------------

# Global constants
REPORT_DIR="/var/tmp/high_load_reports"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
REPORT_FILE="${REPORT_DIR}/report_${TIMESTAMP}.log"

# Ensure report directory exists
mkdir -p "${REPORT_DIR}"

# Helper: write timestamped messages to both stdout and report file
log() {
    local msg="$*"
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${msg}" | tee -a "${REPORT_FILE}"
}

# Helper: verify required binaries are present
require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        log "ERROR: Required command '${cmd}' not found in PATH."
        exit 1
    fi
}

# ----------------------------------------------------------------------
# Section 1 – Immediate Verification
# ----------------------------------------------------------------------
verify_load() {
    log "=== Immediate Verification ==="

    # Core count and threshold
    local cores
    cores=$(nproc)
    local threshold=$(( cores * 2 ))
    log "CPU cores detected          : ${cores}"
    log "Load threshold (2×cores)    : ${threshold}"

    # Current load averages (1, 5, 15 min)
    local load1 load5 load15
    read -r load1 load5 load15 _ < <(awk '{print $1,$2,$3}' /proc/loadavg)
    log "Current load averages       : 1min=${load1} 5min=${load5} 15min=${load15}"

    # Comparison (using integer part of 1‑minute load)
    local load_int
    load_int=$(printf "%.0f" "${load1}")
    if (( load_int > threshold )); then
        log "ALERT: Load (${load1}) exceeds threshold (${threshold})."
        return 0    # indicate overload condition
    else
        log "INFO: Load (${load1}) is within acceptable range."
        return 1    # no overload
    fi
}

# ----------------------------------------------------------------------
# Section 2 – Core Diagnostic Areas
# ----------------------------------------------------------------------
collect_diagnostics() {
    log "=== Core Diagnostics ==="

    # CPU saturation
    require_cmd ps
    log "--- Top CPU consumers (ps) ---"
    ps -eo pid,ppid,user,%cpu,command --sort=-%cpu | head -n 15 | tee -a "${REPORT_FILE}"

    # I/O bottlenecks
    if command -v iostat >/dev/null 2>&1; then
        log "--- I/O statistics (iostat) ---"
        iostat -xz 5 3 | tee -a "${REPORT_FILE}"
    else
        log "WARNING: iostat not installed; skipping I/O stats."
    fi

    # Memory pressure / swapping
    require_cmd free
    log "--- Memory usage (free) ---"
    free -m | tee -a "${REPORT_FILE}"

    # Kernel scheduler / runqueue length
    log "--- /proc/loadavg snapshot ---"
    cat /proc/loadavg | tee -a "${REPORT_FILE}"

    # Interrupt storms
    require_cmd vmstat
    log "--- vmstat (interrupt/wait) ---"
    vmstat -w 5 3 | tee -a "${REPORT_FILE}"

    # Docker container limits (optional)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        log "--- Docker container stats ---"
        docker stats --no-stream | tee -a "${REPORT_FILE}"
    else
        log "INFO: Docker not available; skipping container stats."
    fi
}

# ----------------------------------------------------------------------
# Section 3 – Detailed Investigation Steps
# ----------------------------------------------------------------------
deep_investigation() {
    log "=== Detailed Investigation ==="

    # Step 1: Baseline CPU utilization per core
    if command -v mpstat >/dev/null 2>&1; then
        log "--- mpstat per CPU (5 sec interval, 3 samples) ---"
        mpstat -P ALL 5 3 | tee -a "${REPORT_FILE}"
    else
        log "WARNING: mpstat not installed; skipping per‑CPU stats."
    fi

    # Step 2: Top‑CPU processes via top (batch mode)
    require_cmd top
    log "--- top (sorted by %CPU) ---"
    top -b -o +%CPU -n 1 | head -n 25 | tee -a "${REPORT_FILE}"

    # Step 3: Disk latency & queue depth via iotop
    if command -v iotop >/dev/null 2>&1; then
        log "--- iotop (disk I/O) ---"
        iotop -b -n 5 -d 2 | tee -a "${REPORT_FILE}"
    else
        log "WARNING: iotop not installed; skipping disk I/O details."
    fi

    # Step 4: Memory & swap activity via vmstat
    log "--- vmstat (memory & swap) ---"
    vmstat 5 5 | tee -a "${REPORT_FILE}"

    # Step 5: Kernel ring buffer for hardware errors
    require_cmd dmesg
    log "--- dmesg (errors/irqs) ---"
    dmesg | grep -iE 'error|fail|irq' | tee -a "${REPORT_FILE}"
}

# ----------------------------------------------------------------------
# Section 5 – Short‑Term Mitigation (interactive)
# ----------------------------------------------------------------------
short_term_mitigation() {
    log "=== Short‑Term Mitigation Options ==="
    echo "Select an action:"
    echo " 1) Pause a non‑critical PID"
    echo " 2) Lower priority of a PID"
    echo " 3) Create temporary swap file"
    echo " 4) Skip mitigation"
    read -rp "Enter choice [1-4]: " choice

    case "$choice" in
        1)
            read -rp "Enter PID to STOP: " pid
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                sudo kill -STOP "$pid"
                log "Sent SIGSTOP to PID $pid."
            else
                log "Invalid PID."
            fi
            ;;
        2)
            read -rp "Enter PID to renice: " pid
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                sudo renice +19 -p "$pid"
                log "Reniced PID $pid to +19."
            else
                log "Invalid PID."
            fi
            ;;
        3)
            local swapfile="/swapfile.tmp"
            log "Creating 4GiB temporary swap at ${swapfile}..."
            sudo fallocate -l 4G "${swapfile}"
            sudo chmod 600 "${swapfile}"
            sudo mkswap "${swapfile}"
            sudo swapon "${swapfile}"
            log "Temporary swap enabled."
            ;;
        *)
            log "No mitigation performed."
            ;;
    esac
}

# ----------------------------------------------------------------------
# Main Execution Flow
# ----------------------------------------------------------------------
main() {
    log "===== High Load Investigation Started ====="
    if verify_load; then
        collect_diagnostics
        deep_investigation
        short_term_mitigation
        log "Re‑checking load after mitigation..."
        if verify_load; then
            log "WARN: Load still above threshold after mitigation."
        else
            log "SUCCESS: Load now below threshold."
        fi
    else
        log "System load is normal; no further action required."
    fi
    log "Report saved to ${REPORT_FILE}"
    log "===== Investigation Completed ====="
}

main "$@"