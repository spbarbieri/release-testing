#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# Memory Exhaustion Diagnostic Script
# Generates a comprehensive report on current memory state,
# top consumers, swap, OOM events, cgroup limits, and system settings.
# The report is emailed to the designated stakeholders.
# ----------------------------------------------------------------------

# --------------------------- Configuration -----------------------------
REPORT_ROOT="/var/tmp/memory_diagnostics"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
HOSTNAME="$(hostname)"
REPORT_FILE="${REPORT_ROOT}/${HOSTNAME}_memory_report_${TIMESTAMP}.txt"

EMAIL_RECIPIENTS="ops-team@example.com"
EMAIL_SUBJECT="[Memory Alert] ${HOSTNAME} diagnostics ${TIMESTAMP}"

# Optional: Path to mail utility (compatible with both mail and mailx)
MAIL_CMD="$(command -v mail || command -v mailx || true)"

# ---------------------------- Helpers ---------------------------------
log_section() {
    local title="$1"
    printf "\n===== %s =====\n\n" "$title" >>"$REPORT_FILE"
}

run_cmd() {
    local description="$1"
    shift
    local cmd=("$@")
    log_section "$description"
    if "${cmd[@]}" >>"$REPORT_FILE" 2>&1; then
        :
    else
        echo "[ERROR] Command failed: ${cmd[*]}" >>"$REPORT_FILE"
    fi
}

ensure_dir() {
    mkdir -p "$REPORT_ROOT"
    chmod 750 "$REPORT_ROOT"
}
# ---------------------------------------------------------------------

ensure_dir
: >"$REPORT_FILE"   # truncate/create report file

# -------------------------- Memory Utilization -------------------------
run_cmd "Current memory utilization (free -m)" free -m
run_cmd "/proc/meminfo snapshot" cat /proc/meminfo

# ---------------------- Top Memory Consuming Processes -----------------
run_cmd "Top 10 memory consuming processes (ps)" \
    ps -eo pid,ppid,cmd,%mem --sort=-%mem | head -n 11
run_cmd "Top processes snapshot (top -b -n1)" \
    top -b -n1 | head -n 15

# ------------------------ Historical Memory Trend ---------------------
if command -v sar >/dev/null 2>&1; then
    run_cmd "Historical memory usage (sar -r 1 10)" sar -r 1 10
else
    log_section "Historical memory usage"
    echo "sar command not found; install sysstat package to enable." >>"$REPORT_FILE"
fi

# ----------------------- Swap & Swappiness ----------------------------
run_cmd "Active swap devices (swapon --show)" swapon --show
run_cmd "Swappiness setting (sysctl vm.swappiness)" sysctl vm.swappiness

# -------------------------- OOM Events -------------------------------
run_cmd "Kernel OOM messages (dmesg)" dmesg | grep -i oom || echo "No OOM messages found."
run_cmd "Kernel kill messages (journalctl)" journalctl -k | grep -i kill || echo "No kill messages found."

# ------------------- Container / Cgroup Memory Limits -----------------
if command -v docker >/dev/null 2>&1; then
    run_cmd "Docker container live memory usage (docker stats)" docker stats --no-stream
    # List Docker container IDs and their memory limits if available
    CONTAINER_IDS=$(docker ps -q) || true
    if [[ -n "$CONTAINER_IDS" ]]; then
        log_section "Docker container memory limits"
        while IFS= read -r cid; do
            LIMIT_PATH="/sys/fs/cgroup/memory/docker/${cid}/memory.limit_in_bytes"
            if [[ -f "$LIMIT_PATH" ]]; then
                echo "Container $cid limit:" >>"$REPORT_FILE"
                cat "$LIMIT_PATH" >>"$REPORT_FILE"
            else
                echo "Container $cid: No memory limit file found." >>"$REPORT_FILE"
            fi
        done <<<"$CONTAINER_IDS"
    else
        echo "No running Docker containers detected." >>"$REPORT_FILE"
    fi
else
    log_section "Docker container memory usage"
    echo "Docker CLI not installed or not running." >>"$REPORT_FILE"
fi

# --------------------- System Limits & Overcommit --------------------
run_cmd "Per-process limits (ulimit -a)" ulimit -a
run_cmd "Overcommit policy (sysctl vm.overcommit_memory)" sysctl vm.overcommit_memory

# ------------------------- Remediation Suggestions -------------------
log_section "Recommended Remediation Actions"
cat <<'EOF' >>"$REPORT_FILE"
Immediate Relief:
  • Stop or restart high-memory processes identified above.
  • Flush caches safely: sync && echo 3 > /proc/sys/vm/drop_caches

Swap Adjustment:
  • Increase swap size (example creates 4GiB swapfile):
      dd if=/dev/zero of=/swapfile bs=1M count=4096
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
  • Tune swappiness: sysctl -w vm.swappiness=60

Application Optimisation:
  • Reduce JVM heap (-Xmx), Python worker pools, DB connections, etc.
  • Enforce container memory limits (e.g., docker run --memory=2g)

Kernel Parameters:
  • Allow aggressive allocation: sysctl -w vm.overcommit_memory=1
  • Persist changes in /etc/sysctl.conf

Long‑term Measures:
  • Add physical RAM if trends persist.
  • Clean orphaned packages/files (apt-get autoremove, yum clean all, rm -rf /tmp/*).

Preventive Steps:
  • Deploy monitoring alerts (>80% memory usage).
  • Define cgroup/quota limits for critical services.
  • Schedule daily health checks via cron (free -m >> /var/log/memory_daily.log).
EOF

# ----------------------------- Email Report ---------------------------
if [[ -n "$MAIL_CMD" ]]; then
    echo "Sending memory diagnostic report to $EMAIL_RECIPIENTS ..."
    cat "$REPORT_FILE" | "$MAIL_CMD" -s "$EMAIL_SUBJECT" "$EMAIL_RECIPIENTS"
else
    echo "Mail utility not found. Please manually send the report located at:"
    echo "$REPORT_FILE"
fi

echo "Memory bhadri diagnostic completed. Report saved to $REPORT_FILE"