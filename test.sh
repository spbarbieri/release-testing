#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
CPU_PROC_THRESHOLD=80.0      # % CPU usage per process considered excessive
TOTAL_CPU_THRESHOLD=90.0     # % of total CPU capacity (based on load avg) that triggers a warning
WHITELIST=("sshd" "init" "systemd" "bash" "cron")  # Processes never to terminate

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------
is_whitelisted() {
    local proc_name="$1"
    for w in "${WHITELIST[@]}"; do
        [[ "$proc_name" == "$w" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# Gather system-wide CPU metrics
# ------------------------------------------------------------
read -r load1 load5 load15 < /proc/loadavg
cpu_cores=$(nproc)

# Convert 1‑minute load average to a percentage of total core capacity
load_percent=$(awk "BEGIN {printf \"%.2f\", ($load1/$cpu_cores)*100}")

echo "=== System Load ==="
printf "Load avg (1m): %.2f (%.2f%% of %d cores)\n" "$load1" "$load_percent" "$cpu_cores"

if (( $(awk "BEGIN {print ($load_percent > $TOTAL_CPU_THRESHOLD)}") )); then
    echo "WARNING: Overall CPU load exceeds ${TOTAL_CPU_THRESHOLD}%."
fi

# ------------------------------------------------------------
# List top CPU‑consuming processes
# ------------------------------------------------------------
process_list=$(ps -eo pid,comm,%cpu --sort=-%cpu | awk 'NR>1')
echo "=== Top CPU Consumers (up to 10) ==="
printf "%-8s %-20s %s\n" "PID" "COMMAND" "CPU%"
echo "$process_list" | head -n 10

# ------------------------------------------------------------
# Detect and flag abnormal processes
# ------------------------------------------------------------
declare -a to_kill=()

while IFS= read -r line; do
    pid=$(awk '{print $1}' <<<"$line")
    cmd=$(awk '{print $2}' <<<"$line")
    cpu=$(awk '{print $3}' <<<"$line")
    [[ -z "$pid" ]] && continue

    # Flag if CPU exceeds per‑process threshold
    if (( $(awk "BEGIN {print ($cpu > $CPU_PROC_THRESHOLD)}") )); then
        if is_whitelisted "$cmd"; then
            echo "SKIP: Whitelisted $cmd (PID $pid) uses $cpu% CPU."
        else
            echo "MARK: $cmd (PID $pid) uses $cpu% CPU → candidate for termination."
            to_kill+=("$pid")
        fi
    fi
done <<<"$process_list"

# ------------------------------------------------------------
# Terminate flagged processes (with safety checks)
# ------------------------------------------------------------
if (( ${#to_kill[@]} )); then
    echo "Processes slated for termination: ${to_kill[*]}"
    
    # Non‑interactive mode bypasses prompt
    if [[ "${NON_INTERACTIVE:-}" != "true" ]]; then
        read -rp "Proceed with termination? [y/N] " ans
        ans=${ans,,}
        if [[ "$ans" != y && "$ans" != yes ]]; then
            echo "Termination aborted by user."
            exit 0
        fi
    fi

    # Graceful shutdown first
    for pid in "${to_kill[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    # Allow processes time to exit cleanly
    sleep 5

    # Force kill any that remain
    for pid in "${to_kill[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            echo "Force killing PID $pid."
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
else
    echo "No abnormal high‑CPU processes detected."
fi

# ------------------------------------------------------------
# Capacity recommendation
# ------------------------------------------------------------
if (( $(awk "BEGIN {print ($load_percent > $TOTAL_CPU_THRESHOLD)}") )); then
    echo "RECOMMENDATION: Consider migrating workloads to another host or scaling up CPU resources."
fi

exit 0