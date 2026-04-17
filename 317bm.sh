#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose a Kubernetes worker node and attempt recovery.
# ------------------------------------------------------------

# Configuration
LOG_JOURNAL_UNIT="kubelet"
LOG_SINCE="${LOG_SINCE:-\"24h\"}"   # How far back to search logs (default 24 hours)
KUBELET_SERVICE="kubelet"

# Determine node identifier (use provided arg or fallback to hostname)
NODE_NAME="${1:-$(hostname)}"

# Helper: Print timestamped messages
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${NODE_NAME}] $*"
}

# 1. Check node logs for errors or warnings
check_logs() {
    log_msg "Scanning ${LOG_JOURNAL_UNIT} logs for errors or warnings..."
    if ! journalctl -u "${LOG_JOURNAL_UNIT}" --since "${LOG_SINCE}" | \
        grep -iE "(error|warning)" > /tmp/k8s_log_issues.txt; then
        log_msg "No error or warning entries found in recent logs."
        return 0
    fi

    log_msg "Found potential issues in logs:"
    cat /tmp/k8s_log_issues.txt
    return 1
}

# 2. Verify node appears healthy via kubectl
verify_node_status() {
    log_msg "Querying cluster state with 'kubectl get nodes'..."
    if ! kubectl get nodes "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' >/dev/null 2>&1; then
        log_msg "Node '${NODE_NAME}' not listed in cluster output."
        return 2
    fi

    local ready_status
    ready_status=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [[ "${ready_status}" == "True" ]]; then
        log_msg "Node status: Ready"
        return 0
    else
        log_msg "Node status: Not Ready (${ready_status})"
        return 1
    fi
}

# 3. Validate network configuration (IP address presence)
check_network() {
    log_msg "Inspecting network interfaces..."
    if ip addr show | grep -q "inet "; then
        log_msg "At least one IPv4 address is configured."
        return 0
    else
        log_msg "No IP address detected on any interface."
        return 1
    fi
}

# 4. Attempt to recover by restarting kubelet
restart_kubelet() {
    log_msg "Attempting to restart ${KUBELET_SERVICE} service..."
    systemctl restart "${KUBELET_SERVICE}"
    log_msg "${KUBELET_SERVICE} restarted successfully."

    # Give kubelet a moment to re-register
    sleep 10

    # Re‑check node readiness after restart
    verify_node_status && log_msg "Node recovered and is now Ready." || \
        log_msg "Node still not Ready after restart."
}

# -------------------- Main Execution Flow --------------------
if ! check_logs; then
    # Errors/warnings were found – abort further checks
    log_msg "Investigate logged issues before proceeding."
    exit 1
fi

node_check_result=0
if ! node_check_result=$(verify_node_status); then
    case $? in
        2)  # Node not present in cluster
            log_msg "Node not reachable from master. Checking local network config..."
            if ! check_network; then
                log_msg "Network misconfiguration detected. Resolve IP assignment before retrying."
                exit 2
            fi
            ;;
        1)  # Node present but Not Ready
            log_msg "Node reachable but reports Bad/NotReady condition."
            restart_kubelet
            ;;
    esac
else
    log_msg "Node is healthy. No action required."
fi

exit 0