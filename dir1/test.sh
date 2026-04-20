#!/bin/bash
# ==============================================================================
# Script: diagnose_event_noise.sh
# Purpose: Automate data‑collection, verification and initial analysis for the
#          repetitive “New event Event New event with description ss”
#          messages observed in JVM logs.
#
# Requirements:
#   - Bash 4+
#   - Java tools (jps, jcmd, jstat, jstack, jmap)
#   - System utilities (journalctl, top, vmstat, grep, git, tar)
#
# Usage:
#   ./diagnose_event_noise.sh -s <service_name> [-o <output_dir>]
#
# Example:
#   ./diagnose_event_noise.sh -s myapp-service -o /tmp/event_diagnosis
# ==============================================================================

set -euo pipefail

# ----------------------------- Helper Functions ---------------------------------

usage() {
    cat <<EOF
Usage: $0 -s <service_name> [-o <output_directory>]

  -s   Name of the systemd service hosting the JVM (required)
  -o   Directory where all artifacts will be stored (default: /tmp/event_diag_\<timestamp\>)
  -h   Show this help message
EOF
    exit 1
}

log_msg() {
    local msg="\$@"
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$msg"
}

check_cmd() {
    command -v "\$1" >/dev/null 2>&1 || {
        echo "Error: Required command '\$1' not found in PATH."
        exit 1
    }
}

# --------------------------- Argument Parsing ----------------------------------

SERVICE_NAME=""
OUTPUT_ROOT=""

while getopts ":s:o:h" opt; do
    case "\$opt" in
        s) SERVICE_NAME="\$OPTARG" ;;
        o) OUTPUT_ROOT="\$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "\$SERVICE_NAME" ]]; then
    echo "Error: Service name is mandatory."
    usage
fi

TIMESTAMP=\$(date '+%Y%m%d_%H%M%S')
DEFAULT_OUT="/tmp/event_diag_\${TIMESTAMP}"
OUTPUT_ROOT=\${OUTPUT_ROOT:-\$DEFAULT_OUT}
mkdir -p "\$OUTPUT_ROOT"

# Create sub‑directories for organization
LOG_DIR="\$OUTPUT_ROOT/logs"
SRC_ANALYSIS_DIR="\$OUTPUT_ROOT/src_analysis"
mkdir -p "\$LOG_DIR" "\$SRC_ANALYSIS_DIR"

log_msg "Output directory: \$OUTPUT_ROOT"

# -------------------------- Prerequisite Checks --------------------------------

REQUIRED_CMDS=(jps jcmd top vmstat jstat jstack jmap java journalctl grep git tar)
for cmd in "\${REQUIRED_CMDS[@]}"; do
    check_cmd "\$cmd"
done

# -------------------------- Initial Data Collection ----------------------------

log_msg "Collecting Java process list..."
jps -l > "\$LOG_DIR/jps_l.txt"

# Extract Java PIDs (ignore header line if present)
JAVA_PIDS=()
while read -r line; do
    pid=\$(echo "\$line" | awk '{print \$1}')
    # Basic sanity check – numeric PID
    if [[ "\$pid" =~ ^[0-9]+\$ ]]; then
        JAVA_PIDS+=(\"\$pid\")
    fi
done < "\$LOG_DIR/jps_l.txt"

if [ \${#JAVA_PIDS[@]} -eq 0 ]; then
    log_msg "No Java processes detected on the host. Exiting."
    exit 1
fi

log_msg "Detected Java PIDs: \${JAVA_PIDS[*]}"

log_msg "Capturing JVM version..."
java -version &> "\$LOG_DIR/java_version.txt"

log_msg "Gathering jcmd listing (with dummy JMX port)..."
jcmd -J-Dcom.sun.management.jmxremote.port=0 -l > "\$LOG_DIR/jcmd_l.txt"

log_msg "Fetching recent journal entries for service '\$SERVICE_NAME'..."
journalctl -u "\$SERVICE_NAME" --since "5 minutes ago" > "\$LOG_DIR/journalctl_recent.txt"

# -------------------------- Symptom Verification ------------------------------

log_msg "Recording one‑shot top snapshot..."
top -b -n 1 > "\$LOG_DIR/top_snapshot.txt"

log_msg "Running vmstat (1 sec interval, 5 samples)..."
vmstat 1 5 > "\$LOG_DIR/vmstat.txt"

for pid in "\${JAVA_PIDS[@]}"; do
    log_msg "Collecting jstat GC utilization for PID \$pid (interval 1000ms, 5 iterations)..."
    jstat -gcutil "\$pid" 1000 5 > "\$LOG_DIR/jstat_gcutil_\${pid}.txt" 2>/dev/null || true

    log_msg "Dumping stack trace for PID \$pid..."
    jstack -p "\$pid" > "\$LOG_DIR/jstack_\${pid}.txt" 2>/dev/null || true

    log_msg "Generating heap summary via jmap for PID \$pid..."
    jmap -heap "\$pid" > "\$LOG_DIR/jmap_heap_\${pid}.txt" 2>/dev/null || true
done

# -------------------------- Root Cause Preliminary Analysis -------------------

log_msg "Searching source tree for the exact event string..."
# Assuming source resides under /opt/app/src ; adjust if needed
SOURCE_ROOT="/opt/app/src"
if [ -d "\$SOURCE_ROOT" ]; then
    grep -R --binary-files=without-match -n "Event New event" "\$SOURCE_ROOT" > "\$SRC_ANALYSIS_DIR/grep_event_strings.txt" || true
else
    log_msg "Source directory \$SOURCE_ROOT not found; skipping source grep."
fi

log_msg "Scanning Git history for recent commits mentioning 'event'..."
# Detect repository root relative to script location
if git rev-parse --show-toplevel >/dev/null 2>&1; then
    GIT_ROOT=\$(git rev-parse --show-toplevel)
    pushd "\$GIT_ROOT" >/dev/null
    git log -p --grep="event" > "\$SRC_ANALYSIS_DIR/git_log_event.txt"
    popd >/dev/null
else
    log_msg "Git repository not detected from current directory; skipping git log scan."
fi

# -------------------------- Summary Packaging ----------------------------------

ARCHIVE_PATH="\$OUTPUT_ROOT/event_diagnosis_\${TIMESTAMP}.tar.gz"
log_msg "Creating compressed archive of collected artifacts..."
tar -czf "\$ARCHIVE_PATH" -C "\$OUTPUT_ROOT" .

log_msg "Data collection complete. Archive created at:"
log_msg "\$ARCHIVE_PATH"

# -------------------------- Post‑Collection Guidance --------------------------

cat <<EOG

=== Next Steps ===

1. Review the archived logs (extract with: tar -xzf $ARCHIVE_PATH -C <dest>) 
   focusing on:
   * \$LOG_DIR/jps_l.txt            – verify which JVM instance produced the noise.
   * \$LOG_DIR/jstat_gcutil_*.txt   – look for abnormal GC activity coincident with events.
   * \$LOG_DIR/jstack_*.txt         – inspect threads at the time of logging.
   * \$SRC_ANALYSIS_DIR/grep_event_strings.txt – locate potential hard‑coded logger calls.
   * \$SRC_ANALYSIS_DIR/git_log_event.txt      – identify recent code changes.

2. If the offending line is found in application code, consider lowering its
   log level (e.g., DEBUG → INFO) or removing it entirely for production.

3. If a monitoring/agent component is responsible, adjust its configuration
   to suppress the specific event type and restart the service:
       sudo systemctl restart $SERVICE_NAME

4. For JVM‑level diagnostics, verify that no unwanted diagnostic flags are
   enabled (e.g., -XX:+UnlockDiagnosticVMOptions). Amend the startup options
   accordingly, e.g.:
       JAVA_OPTS="-Xlog:gc* -XX:-PrintGCDetails"
   and redeploy/restart the service.

5. After remediation, monitor the application log for at least 24 hours:
       tail -F /var/log/$SERVICE_NAME/application.log

   Additionally, you may run baseline performance checks:
       sar -u 1 10

6. To prevent recurrence, add a filter rule to your centralized logging pipeline
   (Logstash/Fluentd) that drops the known benign message pattern.

7. Document findings, remediation steps, and any configuration changes in the
   incident tracking system and communicate updates via the standard release
   notes channel.

EOG

exit 0