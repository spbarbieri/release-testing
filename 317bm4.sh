#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1. Scan recent kubelet logs for errors or warnings.
#   2. Verify node status via `kubectl get nodes`.
#   3. If node is not reachable, confirm the node has a valid IP.
#   4. If node is reachable but in a bad condition, restart kubelet.
# ------------------------------------------------------------

# Configuration
LOG_LOOKBACK="1h"               # How far back to search logs (compatible with journalctl)
KUBELET_UNIT="kubelet"
MAX_LOG_LINES=1000              # Limit displayed log lines when errors are found

# Helper: print timestamped messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

# Step 1 – Examine kubelet logs for errors or warnings
log "Checking kubelet logs for errors or warnings (last ${LOG_LOOKBACK})..."
if command -v journalctl >/dev/null 2>&1; then
    LOG_OUTPUT=$(journalctl -u "${KUBELET_UNIT}" --since="${LOG_LOOKBACK}" \
                 | grep -Ei "(error|warn)" || true)
else
    # Fallback to syslog if journalctl unavailable
    LOG_FILE="/var/log/kubelet.log"
    if [[ -f "${LOG_FILE}" ]]; then
        LOG_OUTPUT=$(awk -v d="$(date -d "-${LOG_LOOKBACK}" +'%b %_d %H:%M:%S')" '$0 > d' "${LOG_FILE}" \
                     | grep -Ei "(error|warn)" || true)
    else
        LOG_OUTPUT=""
    fi
fi

if [[ -n "${LOG_OUTPUT}" ]]; then
    log "Found error/warning entries in kubelet logs:"
    echo "${LOG_OUTPUT}" | head -n "${MAX_LOG_LINES}"
    log "Please investigate the above log entries before proceeding."
    exit 1
else
    log "No error or warning messages detected in recent kubelet logs."
fi

# Step 2 – Verify node status via kubectl
NODE_NAME=$(hostname -s)
log "Retrieving node status for '${NODE_NAME}' from the control plane..."
if ! command -v kubectl >/dev/null 2>&1; then
    log "ERROR: kubectl not installed or not in PATH."
    exit 2
fi

# Capture the line corresponding to this node
NODE_LINE=$(kubectl get nodes -o wide | awk -v n="${NODE_NAME}" '$1==n')
if [[ -z "${NODE_LINE}" ]]; then
    log "Node '${NODE_NAME}' not listed by the master. It may be unreachable."
    NODE_REACHABLE=false
else
    NODE_STATUS=$(echo "${NODE_LINE}" | awk '{print $2}')
    log "Node status reported as '${NODE_STATUS}'."
    NODE_REACHABLE=true
fi

# Step 3 – If node not reachable, verify network configuration
if [[ "${NODE_REACHABLE}" = false ]]; then
    log "Checking network interfaces for a usable IP address..."
    IP_INFO=$(ip -4 addr show scope global up | awk '/inet/ {print $2}' | cut -d/ -f1)
    if [[ -z "${IP_INFO}" ]]; then
        log "ERROR: No IPv4 address found on any non‑loopback interface."
        exit 3
    else
        log "Detected IP addresses: ${IP_INFO}"
        log "Ensure firewall rules/NAT allow traffic between this node and the control plane."
    fi
    # After confirming IP presence, suggest manual network troubleshooting
    log "Node remains unreachable from the master. Manual network investigation required."
    exit 4
fi

# Step 4 – Node reachable but in a bad condition → restart kubelet
if [[ "${NODE_STATUS}" != "Ready" ]]; then
    log "Node is reachable but not in Ready state ('${NODE_STATUS}'). Attempting to restart kubelet..."
    if ! command -v systemctl >/dev/null 2>&1; then
        log "ERROR: systemctl not available; cannot manage kubelet service."
        exit 5
    fi

    sudo systemctl restart "${KUBELET_UNIT}"
    log "kubelet service restarted. Waiting briefly for status to settle..."
    sleep 15

    # Re‑query node status
    NEW_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [[ "${NEW_STATUS}" == "True" ]]; then
        log "Node has transitioned to Ready state after kubelet restart."
        exit 0
    else
        log "WARNING: Node still not Ready after restarting kubelet (status: ${NEW_STATUS})."
        exit 6
    fi
else
    log "Node is already in Ready state. No further action required."
    exit 0
fi