#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: system_load_check.sh
# Purpose: Collects load information, monitors resources,
#          and provides basic guidance for high load cases.
# ------------------------------------------------------------

# Helper to print section headers
print_header() {
    echo
    echo "===== $* ====="
}

# ------------------------------------------------------------------
# Determine CPU core count and define a simple overload threshold.
# Threshold = 2 × number of logical CPUs (adjustable per policy).
# ------------------------------------------------------------------
if command -v nproc >/dev/null; then
    CPU_CORES=$(nproc)
else
    # Fallback: parse /proc/cpuinfo
    CPU_CORES=$(grep -c '^processor' /proc/cpuinfo || echo 1)
fi
THRESHOLD=$((CPU_CORES * 2))

# ------------------------------------------------------------------
# 1. Show uptime and evaluate 1‑minute load against the threshold.
# ------------------------------------------------------------------
print_header "Uptime and Load Averages"

if command -v uptime >/dev/null; then
    UPTIME_OUT=$(uptime)
    echo "$UPTIME_OUT"

    # Extract the three load numbers (format may vary slightly)
    LOAD_STR=$(echo "$UPTIME_OUT" | awk -F'load average:' '{print $2}' | tr -d ' ')
    read -r LOAD_1 MIN5 MIN15 <<<"$LOAD_STR"

    echo "Load averages → 1m: $LOAD_1   5m: $MIN5   15m: $MIN15"
    # Numeric comparison – use bc/awk for floating point
    if awk "BEGIN{exit !($LOAD_1 > $THRESHOLD)}"; then
        echo "WARNING: 1‑minute load ($LOAD_1) exceeds threshold ($THRESHOLD)."
    else
        echo "OK: 1‑minute load ($LOAD_1) is within threshold ($THRESHOLD)."
    fi
else
    echo "ERROR: 'uptime' command not found."
fi

# ------------------------------------------------------------------
# 2. Continuous vmstat sampling (1‑second interval, 5 iterations).
# ------------------------------------------------------------------
print_header "VMStat Sampling (1 s interval, 5 samples)"

if command -v vmstat >/dev/null; then
    vmstat 1 5
else
    echo "ERROR: 'vmstat' command not found."
fi

# ------------------------------------------------------------------
# 3. Capture a quick snapshot of top (batch mode) or fallback to ps.
# ------------------------------------------------------------------
print_header "Top Snapshot (Batch Mode, 1 Iteration)"

if command -v top >/dev/null; then
    top -b -n 1 | head -n 20
elif command -v htop >/dev/null; then
    # htop lacks a reliable non‑interactive dump; use ps instead.
    echo "'htop' detected but batch mode unavailable – using ps."
    ps aux --sort=-%cpu | head -n 20
else
    echo "ERROR: Neither 'top' nor 'htop' is installed."
fi

# ------------------------------------------------------------------
# 4. Directly read /proc/loadavg for raw values.
# ------------------------------------------------------------------
print_header "/proc/loadavg Contents"

if [[ -r /proc/loadavg ]]; then
    PROC_LOAD=$(< /proc/loadavg)
    echo "$PROC_LOAD"
    read -r P1 P5 P15 _ <<<"$PROC_LOAD"
    echo "Parsed → 1m: $P1   5m: $P5   15m: $P15"
else
    echo "ERROR: Unable to read /proc/loadavg."
fi

# ------------------------------------------------------------------
# 5. Brief investigative checklist.
# ------------------------------------------------------------------
print_header "Investigative Checklist"

cat <<'EOF'
Potential root causes of elevated load:
- Misconfigured services (excessive workers, runaway cron jobs)
- CPU‑bound applications (tight loops, unoptimized code)
- Memory pressure leading to swapping
- High I/O wait (%wa) observed in vmstat
- Disk latency, network bottlenecks, or kernel bugs

Suggested next steps:
1. Identify top consumers from the 'top'/'ps' output.
2. Review relevant logs (journalctl, /var/log/*) for errors.
3. Adjust service configuration limits or restart problematic daemons.
4. If hardware limits are hit, consider scaling CPU or improving storage.
5. Re‑run this script after changes to verify improvement.
EOF

# End of script