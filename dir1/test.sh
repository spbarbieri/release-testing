#!/bin/bash
#
# mq_depth_event_diagnostic.sh
#
# Automated diagnostics for IBM MQ depth events (e.g., MQDepthEventTest03).
# Retrieves the latest event from the designated event queue, extracts the
# affected queue name, and runs a series of investigative commands.
#
# Usage:
#   ./mq_depth_event_diagnostic.sh -m <QMGR> [-e <EVENT_QUEUE>] [-t <EVENT_TYPE>] [-o <OUTPUT_DIR>]
#
# Example:
#   ./mq_depth_event_diagnostic.sh -m PROD.QMGR -e EVENT.QMGR -t MQDepthEventTest03 -o /tmp/mq_diag
#

set -euo pipefail

# ---------- Default values ----------
EVENT_QUEUE="EVENT.QMGR"
EVENT_TYPE="MQDepthEventTest03"
OUTPUT_DIR="/tmp/mq_depth_event_report"

# ---------- Helper functions ----------
print_usage() {
    cat <<EOF
Usage: $0 -m <QMGR> [-e <EVENT_QUEUE>] [-t <EVENT_TYPE>] [-o <OUTPUT_DIR>]

  -m  Queue manager name (required)
  -e  Event queue name (default: ${EVENT_QUEUE})
  -t  Event type/name to look for (default: ${EVENT_TYPE})
  -o  Directory where all command output will be stored (default: ${OUTPUT_DIR})
  -h  Show this help message
EOF
}

check_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '${cmd}' not found in PATH." >&2
        exit 1
    fi
}

runmqsc_cmd() {
    local qmgr="$1"
    local mqsc_cmd="$2"
    echo "${mqsc_cmd}" | runmqsc "${qmgr}"
}

extract_field() {
    # Arguments: $1 = payload string, $2 = field name (case‑insensitive)
    local payload="$1"
    local field="$(echo "$field" | tr '[:lower:]' '[:upper:]')" # normalize
    echo "$payload" | awk -v f="${2^^}" '
        BEGIN{IGNORECASE=1}
        $0 ~ f{
            split($0,a,"[=:]"); 
            for(i=1;i<=length(a);i++){
                if(tolower(a[i])==tolower(f)){
                    gsub(/^[ \t]+|[ \t]+$/,"",a[i+1]);
                    print a[i+1];
                    exit;
                }
            }
        }'
}

timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# ---------- Parse CLI options ----------
while getopts ":m:e:t:o:h" opt; do
    case "${opt}" in
        m) QMGR_NAME="${OPTARG}" ;;
        e) EVENT_QUEUE="${OPTARG}" ;;
        t) EVENT_TYPE="${OPTARG}" ;;
        o) OUTPUT_DIR="${OPTARG}" ;;
        h) print_usage; exit 0 ;;
        *) echo "Invalid option: -${OPTARG}" >&2; print_usage; exit 1 ;;
    esac
done

if [[ -z "${QMGR_NAME:-}" ]]; then
    echo "Error: Queue manager name (-m) is required." >&2
    print_usage
    exit 1
fi

# ---------- Ensure required utilities are present ----------
for cmd in amqsget runmqsc dspmqhist df top grep; do
    check_command "$cmd"
done

# ---------- Prepare output environment ----------
mkdir -p "${OUTPUT_DIR}"
REPORT_FILE="${OUTPUT_DIR}/diagnostic_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${REPORT_FILE}") 2>&1

echo "=== MQ Depth Event Diagnostic Report ==="
echo "Timestamp      : $(timestamp)"
echo "Queue Manager  : ${QMGR_NAME}"
echo "Event Queue    : ${EVENT_QUEUE}"
echo "Target Event   : ${EVENT_TYPE}"
echo "Report Dir     : ${OUTPUT_DIR}"
echo "----------------------------------------"

# ---------- Step 1: Pull latest event from the event queue ----------
echo "[1] Retrieving latest event from ${EVENT_QUEUE} ..."
EVENT_PAYLOAD=$(amqsget "${EVENT_QUEUE}" -m "${QMGR_NAME}" -t 1 2>/dev/null || true)

if [[ -z "${EVENT_PAYLOAD}" ]]; then
    echo "Warning: No messages retrieved from ${EVENT_QUEUE}. Continuing with empty payload."
else
    echo "Raw event payload:"
    echo "${EVENT_PAYLOAD}"
fi

# ---------- Step 2: Validate event type ----------
echo "[2] Verifying event type..."
if [[ -n "${EVENT_PAYLOAD}" ]] && ! echo "${EVENT_PAYLOAD}" | grep -iq "EVENTTYPE[ =]*${EVENT_TYPE}"; then
    echo "Error: Retrieved event does not match expected type '${EVENT_TYPE}'. Aborting."
    exit 1
fi
echo "Event type matches."

# ---------- Step 3: Extract affected queue name ----------
echo "[3] Extracting QUEUENAME from payload..."
QUEUE_NAME=$(echo "${EVENT_PAYLOAD}" | grep -i '^QUEUENAME' | head -n1 | sed -E 's/.*[=:]\s*//')
if [[ -z "${QUEUE_NAME}" ]]; then
    echo "Error: Unable to locate QUEUENAME in event payload."
    exit 1
fi
echo "Affected queue: ${QUEUE_NAME}"

# ---------- Step 4: Display queue attributes ----------
echo "[4] Gathering queue attributes..."
runmqsc_cmd "${QMGR_NAME}" "DISPLAY QLOCAL('${QUEUE_NAME}') CURDEPTH MAXDEPTH THRESHOLD" > "${OUTPUT_DIR}/queue_attributes.txt"
cat "${OUTPUT_DIR}/queue_attributes.txt"

# ---------- Step 5: Depth history (last 24h) ----------
echo "[5] Fetching depth history (last 24h)..."
if command -v dspmqhist >/dev/null 2>&1; then
    dspmqhist -m "${QMGR_NAME}" -q "${QUEUE_NAME}" -s DEPTH -r 24h > "${OUTPUT_DIR}/depth_history.txt" || true
    echo "Depth history saved to ${OUTPUT_DIR}/depth_history.txt"
else
    echo "Skipping dspmqhist: utility not available on this platform."
fi

# ---------- Step 6: Active connections to the queue ----------
echo "[6] Listing active connections to ${QUEUE_NAME} ..."
runmqsc_cmd "${QMGR_NAME}" "DISPLAY CONN(*) WHERE(QNAME EQ '${QUEUE_NAME}')" > "${OUTPUT_DIR}/connections.txt"
cat "${OUTPUT_DIR}/connections.txt"

# ---------- Step 7: Filesystem usage for the queue manager ----------
echo "[7] Checking filesystem space for ${QMGR_NAME} ..."
QMGR_FS_PATH="/var/mqm/qmgrs/${QMGR_NAME}"
df -h "${QMGR_FS_PATH}" > "${OUTPUT_DIR}/filesystem_usage.txt"
cat "${OUTPUT_DIR}/filesystem_usage.txt"

# ---------- Step 8: Host resource snapshot ----------
echo "[8] Capturing CPU/Memory snapshot for MQ processes ..."
top -b -n 1 | grep -Ei 'mqm|ibmmq' > "${OUTPUT_DIR}/host_resources.txt"
cat "${OUTPUT_DIR}/host_resources.txt"

# ---------- Step 9: Scan MQ error logs for depth‑related entries ----------
echo "[9] Searching MQ error logs for depth warnings..."
ERROR_LOG_GLOB="/var/mqm/errors/*.log"
if compgen -G "${ERROR_LOG_GLOB}" > /dev/null; then
    grep -i "depth" ${ERROR_LOG_GLOB} > "${OUTPUT_DIR}/error_log_matches.txt" || true
    echo "Matches (if any) saved to ${OUTPUT_DIR}/error_log_matches.txt"
else
    echo "No error log files found under ${ERROR_LOG_GLOB}"
fi

# ---------- Step 10: Display event definition ----------
echo "[10] Showing definition of event ${EVENT_TYPE} ..."
runmqsc_cmd "${QMGR_NAME}" "DISPLAY EVENT(${EVENT_TYPE}) ALL" > "${OUTPUT_DIR}/event_definition.txt"
cat "${OUTPUT_DIR}/event_definition.txt"

# ---------- Completion ----------
echo "--------------------------------------------------"
echo "Diagnostic collection complete. All artifacts stored in ${OUTPUT_DIR}"
echo "Review the generated files and proceed with root‑cause analysis."
echo "=================================================="