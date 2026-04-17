#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1. Scan kubelet logs for errors or warnings.
#   2. Verify node status via `kubectl get nodes`.
#   3. If node is unreachable, confirm network interface configuration.
#   4. If node is reachable but not Ready, attempt to restart kubelet.
# ------------------------------------------------------------

#--- Configuration -------------------------------------------------
# Adjust these variables as needed for your environment.
KUBELET_SERVICE="kubelet"
LOG_SEARCH_PATTERNS=("error" "warning")
MAX_LOG_LINES=1000          # Number of recent log lines to inspect
NODE_NAME="$(hostname)"     # Assumes the node's hostname matches its name in K8s
#-------------------------------------------------------------------

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

exit_with_error() {
    log "ERROR" "$@"
    exit 1
}

# 1. Examine kubelet logs for errors or warnings
check_logs() {
    log "INFO" "Scanning ${KUBELET_SERVICE} logs for errors/warnings..."
    # Pull recent logs via journalctl; fallback to syslog if unavailable
    if command -v journalctl >/dev/null; then
        LOG_OUTPUT=$(journalctl -u "${KUBELET_SERVICE}" -n "${MAX_LOG_LINES}" --no-pager || true)
    else
        LOG_OUTPUT=$(grep -i "${KUBELET_SERVICE}" /var/log/syslog | tail -n "${MAX_LOG_LINES}" || true)
    fi

    MATCHES=()
    for pattern in "${LOG_SEARCH_PATTERNS[@]}"; do
        while IFS= read -r line; do
            MATCHES+=("$line")
        done < <(printf "%s\n" "$LOG_OUTPUT" | grep -i "$pattern" || true)
    done

    if (( ${#MATCHES[@]} > 0 )); then
        log "WARN" "Found ${#MATCHES[@]} log entries matching error/warning patterns:"
        printf '%s\n' "${MATCHES[@]}"
        exit 0
    else
        log "INFO" "No error or warning messages detected in recent logs."
    fi
}

# 2. Verify node status via kubectl
check_node_status() {
    if ! command -v kubectl >/dev/null; then
        exit_with_error "kubectl command not found. Install/ configure kubectl first."
    fi

    log "INFO" "Fetching node list from the control plane..."
    NODE_TABLE=$(kubectl get nodes -o wide --no-headers)

    # Extract the line corresponding to this node
    NODE_LINE=$(printf "%s\n" "$NODE_TABLE" | awk "\$1 == \"${NODE_NAME}\"")
    if [[ -z "$NODE_LINE" ]]; then
        log "ERROR" "Node '${NODE_NAME}' not present in 'kubectl get nodes' output."
        return 1
    fi

    # Expected columns: NAME STATUS ROLE AGE VERSION INTERNAL-IP EXTERNAL-IP OS-IMAGE KERNEL-VERSION CONTAINER-RUNTIME
    NODE_STATUS=$(awk '{print $2}' <<<"$NODE_LINE")
    log "INFO" "Node '${NODE_NAME}' status reported as: ${NODE_STATUS}"
    echo "$NODE_STATUS"
}

# 3. Validate network interfaces have a non‑loopback IP
verify_network() {
    log "INFO" "Checking network interfaces for assigned IP addresses..."
    IP_INFO=$(ip -brief addr show up primary scope global | awk '{print $1,$3}')
    if [[ -z "$IP_INFO" ]]; then
        log "ERROR" "No active non‑loopback network interfaces detected."
        return 1
    fi

    log "INFO" "Active interfaces with IPs:"
    printf '%s\n' "$IP_INFO"
    return 0
}

# 4. Restart kubelet service
restart_kubelet() {
    log "INFO" "Attempting to restart ${KUBELET_SERVICE} service..."
    if systemctl is-active --quiet "${KUBELET_SERVICE}"; then
        sudo systemctl restart "${KUBELET_SERVICE}"
        log "INFO" "${KUBELET_SERVICE} restarted successfully."
    else
        log "WARN" "${KUBELET_SERVICE} is not currently active; starting it instead."
        sudo systemctl start "${KUBELET_SERVICE}"
    fi
}

#-------------------- Main Execution Flow -------------------------

# Step 1 – Log inspection
check_logs

# Step 2 – Node health via kubectl
STATUS=$(check_node_status) || {
    log "WARN" "Unable to retrieve node status; proceeding to network verification."
    verify_network || exit_with_error "Network verification failed."
    exit 0
}

if [[ "$STATUS" == "Ready" ]]; then
    log "INFO" "Node is healthy (Ready). No further action required."
    exit 0
fi

# At this point the node is listed but not Ready.
log "WARN" "Node status is '${STATUS}'. Investigating possible causes."

# Step 3 – Network connectivity check
if ! verify_network; then
    exit_with_error "Network connectivity appears broken. Resolve networking before retrying."
fi

# Step 4 – Attempt recovery by restarting kubelet
restart_kubelet

# Re‑query status after restart
sleep 10
NEW_STATUS=$(check_node_status) || exit_with_error "Failed to re‑query node status after restart."

if [[ "$NEW_STATUS" == "Ready" ]]; then
    log "INFO" "Node recovered and is now Ready."
else
    log "ERROR" "Node remains in state '${NEW_STATUS}' after kubelet restart. Manual investigation required."
    exit 1
fi