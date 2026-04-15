#!/bin/bash
set -euo pipefail

#====================================================================
# Script: incident_analysis.sh
# Purpose: Automate multi‑step investigation of unexpected errors.
#
# Steps performed:
#   1) Parse network traffic logs for error sources.
#   2) Collect recent system metric snapshots.
#   3) Summarise recent package/configuration changes.
#   4) Run a configurable stress test.
#   5) Provide guidance for consulting plugin documentation/support.
#   6) Offer optional rollback of recent changes.
#
# Author: <Your Name>
#====================================================================

#--------------------------- Configuration ---------------------------
# Log locations – adjust as needed for your environment
NETWORK_LOGS=(
    "/var/log/syslog"
    "/var/log/messages"
    "/var/log/kern.log"
)

# Time window for metric collection (seconds)
METRIC_DURATION=30

# Stress test parameters (requires stress-ng)
STRESS_PROCESSES=4
STRESS_TIMEOUT=60   # seconds

# Output directory for all generated artefacts
REPORT_DIR="/tmp/incident_report_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$REPORT_DIR"

# Email address for support contact (optional)
SUPPORT_EMAIL="support@example.com"

#--------------------------------------------------------------------
# Helper: ensure required binaries exist
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: Required command '$1' not found in PATH." >&2
        exit 1
    }
}

# Verify prerequisites
for cmd in grep awk ss ip awk sed tail head date uname \
           vmstat iostat mpstat sar stress-ng; do
    require_cmd "$cmd"
done

#--------------------------- Step 1 ---------------------------------
analyze_network_logs() {
    local report_file="${REPORT_DIR}/01_network_errors.txt"
    echo "=== Network Traffic Error Analysis ===" >"$report_file"
    echo "Generated on $(date)" >>"$report_file"
    echo "" >>"$report_file"

    local found_any=false
    for logfile in "${NETWORK_LOGS[@]}"; do
        if [[ -f "$logfile" ]]; then
            echo "Scanning $logfile ..." >>"$report_file"
            # Look for typical error keywords and capture source IPs
            grep -iE "error|failed|refused|unreachable" "$logfile" | \
                awk '
                    {
                        # Try to extract IPv4 addresses from the line
                        match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/, m);
                        ip = (m[0] != "") ? m[0] : "N/A";
                        print strftime("%F %T"), ip, $0;
                    }' >>"$report_file" || true
            found_any=true
        else
            echo "Log file $logfile not present, skipping." >>"$report_file"
        fi
    done

    if ! $found_any; then
        echo "No matching log files were found." >>"$report_file"
    fi

    echo "Network analysis complete. Report saved to $report_file"
}

#--------------------------- Step 2 ---------------------------------
collect_system_metrics() {
    local report_file="${REPORT_DIR}/02_system_metrics.txt"
    echo "=== System Metrics Snapshot (${METRIC_DURATION}s) ===" >"$report_file"
    echo "Collected on $(date)" >>"$report_file"
    echo "" >>"$report_file"

    echo "--- CPU & Load ---" >>"$report_file"
    uptime >>"$report_file"
    mpstat 1 "$METRIC_DURATION" >>"$report_file"

    echo "" >>"$report_file"
    echo "--- Memory Usage ---" >>"$report_file"
    vmstat 1 "$METRIC_DURATION" >>"$report_file"

    echo "" >>"$report_file"
    echo "--- Disk I/O ---" >>"$report_file"
    iostat -xz 1 "$METRIC_DURATION" >>"$report_file"

    echo "" >>"$report_file"
    echo "--- Network Connections (top 20 by state) ---" >>"$report_file"
    ss -tunap | sort -k6 | uniq -c | sort -nr | head -n 20 >>"$report_file"

    echo "System metrics collected. Report saved to $report_file"
}

#--------------------------- Step 3 ---------------------------------
summarize_recent_changes() {
    local report_file="${REPORT_DIR}/03_recent_changes.txt"
    echo "=== Recent Package & Config Changes (last 7 days) ===" >"$report_file"
    echo "Generated on $(date)" >>"$report_file"
    echo "" >>"$report_file"

    # Debian/Ubuntu package history
    if [[ -f "/var/log/dpkg.log" ]]; then
        echo "--- dpkg activity ---" >>"$report_file"
        awk -v d="$(date --date='7 days ago' '+%Y-%m-%d')" '$1 >= d {print}' /var/log/dpkg.log >>"$report_file" || true
    fi

    # RHEL/CentOS/Yum history
    if command -v yumhistory >/dev/null 2>&1; then
        echo "--- yum history (last 7 days) ---" >>"$report_file"
        yum history list all | grep "$(date --date='7 days ago' '+%Y')-" >>"$report_file" || true
    fi

    # Git repositories under /etc (common for config-as-code)
    if [[ -d "/etc/.git" ]]; then
        echo "--- Git commits in /etc (last 7 days) ---" >>"$report_file"
        git -C /etc log --since='7 days ago' --oneline >>"$report_file" || true
    fi

    # Modified configuration files in /etc within last 7 days
    echo "--- Recently modified config files in /etc ---" >>"$report_file"
    find /etc -type f -mtime -7 -exec ls -l {} \; 2>/dev/null | sort -k6,7 >>"$report_file" || true

    echo "Recent change summary written to $report_file"
}

#--------------------------- Step 4 ---------------------------------
run_stress_test() {
    local report_file="${REPORT_DIR}/04_stress_test.txt"
    echo "=== Stress Test Execution ===" >"$report_file"
    echo "Started at $(date)" >>"$report_file"
    echo "" >>"$report_file"

    echo "Running stress-ng with ${STRESS_PROCESSES} workers for ${STRESS_TIMEOUT}s..." | tee -a "$report_file"
    stress-ng --cpu "$STRESS_PROCESSES" --timeout "${STRESS_TIMEOUT}s" --metrics-brief >>"$report_file" 2>&1

    echo "" >>"$report_file"
    echo "Stress test completed at $(date)." >>"$report_file"
    echo "Review the above metrics for abnormal behaviour."
}

#--------------------------- Step 5 ---------------------------------
consult_plugin_support() {
    local report_file="${REPORT_DIR}/05_plugin_help.txt"
    echo "=== Plugin Documentation & Support Guidance ===" >"$report_file"
    echo "Generated on $(date)" >>"$report_file"
    echo "" >>"$report_file"

    # Placeholder – replace with actual plugin name/version detection logic
    PLUGIN_NAME="${PLUGIN_NAME:-unknown-plugin}"
    PLUGIN_VERSION="${PLUGIN_VERSION:-latest}"

    echo "Plugin identified: $PLUGIN_NAME (version: $PLUGIN_VERSION)" >>"$report_file"
    echo "" >>"$report_file"
    echo "Recommended actions:" >>"$report_file"
    echo "1. Visit the official documentation page:" >>"$report_file"
    echo "   https://example.com/docs/${PLUGIN_NAME}" >>"$report_file"
    echo "2. Search the knowledge base for known issues related to version $PLUGIN_VERSION." >>"$report_file"
    echo "3. If the issue persists, open a ticket with support:" >>"$report_file"
    echo "   Email: $SUPPORT_EMAIL" >>"$report_file"
    echo "   Subject: \"${PLUGIN_NAME} ${PLUGIN_VERSION} – Unexpected Errors\"" >>"$report_file"

    echo "Support guidance saved to $report_file"
}

#--------------------------- Step 6 ---------------------------------
rollback_changes_prompt() {
    local report_file="${REPORT_DIR}/06_rollback_decision.txt"
    echo "=== Rollback Decision ===" >"$report_file"
    echo "Generated on $(date)" >>"$report_file"
    echo "" >>"$report_file"

    read -rp "Do you want to attempt an automatic rollback of recent package changes? [y/N]: " answer
    case "${answer,,}" in
        y|yes)
            echo "Attempting rollback..." | tee -a "$report_file"
            # Example for Debian/Ubuntu using apt-get
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get install --reinstall $(apt-mark showauto | tr '\n' ' ') || true
                echo "APT packages reinstalled to latest available versions." >>"$report_file"
            elif command -v yum >/dev/null 2>&1; then
                sudo yum history undo last || true
                echo "YUM last transaction undone." >>"$report_file"
            else
                echo "Rollback mechanism not defined for this OS." >>"$report_file"
            fi
            ;;
        *)
            echo "Rollback skipped per operator decision." | tee -a "$report_file"
            ;;
    esac

    echo "Rollback step finished. Details logged in $report_file"
}

#============================ Main Flow ===============================

echo "Incident analysis started. All reports will be stored in $REPORT_DIR"
echo ""

analyze_network_logs
echo ""
collect_system_metrics
echo ""
summarize_recent_changes
echo ""
run_stress_test
echo ""
consult_plugin_support
echo ""
rollback_changes_prompt
echo ""

echo "All steps completed. Consolidated report directory:"
echo "  $REPORT_DIR"
echo "You may archive or share this directory with your team."

exit 0