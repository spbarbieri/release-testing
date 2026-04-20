#!/bin/bash
set -euo pipefail

#====================================================================
# Script: mq_depth_event_diagnostic.sh
# Purpose: Automate diagnostics for IBM MQ depth events (e.g., MQDepthEventTest03)
# Author : Automated Generation
#====================================================================

#---------------------------#
#   Configuration Section   #
#---------------------------#

# Required positional argument: Queue Manager name
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <QUEUE_MANAGER> [EVENT_QUEUE] [EVENT_TYPE]"
    exit 1
fi

QMGR="${1}"
EVENT_QUEUE="${2:-SYSTEM.ADMIN.EVENT}"   # Default MQ event queue
EVENT_TYPE="${3:-MQDepthEventTest03}"    # Default event name to look for

# Directory to store all diagnostic artefacts
REPORT_DIR="/tmp/mq_depth_diag_${QMGR}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${REPORT_DIR}"

# Log helper
log() {
    echo "[${FUNCNAME[1]}] $*" | tee -a "${REPORT_DIR}/script.log"
}

# Verify required utilities are present
for cmd in amqsget runmqsc dspmqhist df top grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' not found in PATH."
        exit 1
    fi
done

#---------------------------#
#   Step 1: Fetch Event     #
#---------------------------#
log "Fetching latest event from ${EVENT_QUEUE} on ${QMGR}"
EVENT_MSG_FILE="${REPORT_DIR}/raw_event.txt"
# amqsget prints the first message and exits when -t 1 is used
amqsget "${EVENT_QUEUE}" -m "${QMGR}" -t 1 > "${EVENT_MSG_FILE}" 2>&1 || true

# Verify we actually retrieved something
if ! grep -q "EVENTTYPE" "${EVENT_MSG_FILE}"; then
    log "No event records found in ${EVENT_QUEUE}. Exiting."
    exit 1
fi

# Save a copy for reference
cp "${EVENT_MSG_FILE}" "${REPORT_DIR}/event_payload.txt"

#---------------------------#
#   Step 2: Parse Payload   #
#---------------------------#
log "Parsing event payload to extract queue name and relevant fields"

# Helper to extract value for a given key (case‑insensitive)
extract_field() {
    local key="$1"
    grep -i "^${key}[[:space:]]*:" "${EVENT_MSG_FILE}" | head -n1 | awk -F': ' '{print $2}' | tr -d '\r'
}

EVENTTYPE=$(extract_field "EVENTTYPE")
QUEUENAME=$(extract_field "QUEUENAME")
CURDEPTH=$(extract_field "CURDEPTH")
MAXDEPTH=$(extract_field "MAXDEPTH")

# Fallback for older formats where keys might be uppercase without colon
if [[ -z "${QUEUENAME}" ]]; then
    QUEUENAME=$(grep -i "QUEUENAME" "${EVENT_MSG_FILE}" | head -n1 | awk -F'=' '{print $2}' | tr -d ' \r')
fi

log "Extracted fields:"
log "  EVENTTYPE = ${EVENTTYPE}"
log "  QUEUENAME = ${QUEUENAME}"
log "  CURDEPTH  = ${CURDEPTH}"
log "  MAXDEPTH  = ${MAXDEPTH}"

if [[ -z "${QUEUENAME}" ]]; then
    log "Unable to determine QUEUENAME from event payload. Aborting."
    exit 1
fi

#---------------------------#
#   Step 3: Queue Attributes#
#---------------------------#
log "Retrieving queue attributes for '${QUEUENAME}'"
QUEUE_ATTR_FILE="${REPORT_DIR}/queue_attributes.txt"
{
    echo "DISPLAY QLOCAL('${QUEUENAME}') CURDEPTH MAXDEPTH THRESHOLD"
} | runmqsc "${QMGR}" > "${QUEUE_ATTR_FILE}" 2>&1
log "Queue attributes saved to ${QUEUE_ATTR_FILE}"

#---------------------------#
#   Step 4: Depth History   #
#---------------------------#
log "Gathering depth history (last 24h) for '${QUEUENAME}'"
DEPTH_HIST_FILE="${REPORT_DIR}/depth_history.txt"
if command -v dspmqhist >/dev/null 2>&1; then
    dspmqhist -m "${QMGR}" -q "${QUEUENAME}" -s DEPTH -r 24h > "${DEPTH_HIST_FILE}" 2>&1 || true
else
    echo "dspmqhist utility not available on this system." > "${DEPTH_HIST_FILE}"
fi
log "Depth history stored in ${DEPTH_HIST_FILE}"

#---------------------------#
#   Step 5: Active Connections #
#---------------------------#
log "Listing active connections referencing the queue"
CONN_FILE="${REPORT_DIR}/active_connections.txt"
{
    echo "DISPLAY CONN(*) WHERE(QNAME EQ '${QUEUENAME}')"
} | runmqsc "${QMGR}" > "${CONN_FILE}" 2>&1
log "Active connections saved to ${CONN_FILE}"

#---------------------------#
#   Step 6: Filesystem Usage #
#---------------------------#
log "Checking filesystem usage for MQ data files"
FS_USAGE_FILE="${REPORT_DIR}/filesystem_usage.txt"
df -h "/var/mqm/qmgrs/${QMGR}" > "${FS_USAGE_FILE}" 2>&1 || true
log "Filesystem usage recorded in ${FS_USAGE_FILE}"

#---------------------------#
#   Step 7: Host Resource Utilization #
#---------------------------#
log "Capturing CPU/Memory snapshot for MQ processes"
TOP_SNAPSHOT="${REPORT_DIR}/top_snapshot.txt"
top -b -n 1 | grep -Ei 'mqm|ibmmq' > "${TOP_SNAPSHOT}" 2>&1 || true
log "Top snapshot saved to ${TOP_SNAPSHOT}"

#---------------------------#
#   Step 8: MQ Error Logs   #
#---------------------------#
log "Searching MQ error logs for depth‑related entries"
ERROR_LOG_GREP="${REPORT_DIR}/error_log_matches.txt"
{
    grep -i "depth" /var/mqm/errors/*.log 2>/dev/null || true
} > "${ERROR_LOG_GREP}"
log "Error log matches stored in ${ERROR_LOG_GREP}"

#---------------------------#
#   Step 9: Event Definition #
#---------------------------#
log "Displaying definition of event '${EVENT_TYPE}'"
EVENT_DEF_FILE="${REPORT_DIR}/event_definition.txt"
{
    echo "DISPLAY EVENT(${EVENT_TYPE}) ALL"
} | runmqsc "${QMGR}" > "${EVENT_DEF_FILE}" 2>&1
log "Event definition written to ${EVENT_DEF_FILE}"

#---------------------------#
#   Step 10: Summary Report #
#---------------------------#
SUMMARY_FILE="${REPORT_DIR}/summary_report.txt"
cat <<EOF > "${SUMMARY_FILE}"
=== MQ Depth Event Diagnostic Summary ===
Timestamp          : $(date)
Queue Manager      : ${QMGR}
Event Queue        : ${EVENT_QUEUE}
Detected Event Type: ${EVENTTYPE}
Affected Queue     : ${QUEUENAME}
Current Depth      : ${CURDEPTH}
Configured MaxDepth: ${MAXDEPTH}

Key Artefacts:
  - Raw Event Payload       : ${EVENT_MSG_FILE}
  - Queue Attributes        : ${QUEUE_ATTR_FILE}
  - Depth History (24h)     : ${DEPTH_HIST_FILE}
  - Active Connections      : ${CONN_FILE}
  - Filesystem Usage        : ${FS_USAGE_FILE}
  - Top Snapshot            : ${TOP_SNAPSHOT}
  - Error Log Matches       : ${ERROR_LOG_GREP}
  - Event Definition        : ${EVENT_DEF_FILE}
  - Full Script Log         : ${REPORT_DIR}/script.log

Next Actions (manual):
  * Review depth history for trend anomalies.
  * Correlate connection IDs with application logs.
  * If MAXDEPTH frequently exceeded, consider ALTER QLOCAL ... MAXDEPTH().
  * Validate event threshold via ALTER EVENT ...
  * Follow remediation checklist as per SOP.

EOF

log "Diagnostic collection complete. Summary available at ${SUMMARY_FILE}"
log "All artefacts stored under ${REPORT_DIR}"

exit 0