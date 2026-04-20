#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1) Scan recent kubelet logs for errors or warnings.
#   2) Verify node appears in `kubectl get nodes`.
#   3) If missing, confirm the node has a non‑loopback IP address.
#   4) If present but not Ready, restart the kubelet service.
# ------------------------------------------------------------

# Configurable parameters
LOG_LOOKBACK="1h"               # How far back to look in logs (e.g., 1h, 30m)
KUBELET_UNIT="kubelet"
MAX_RESTART_ATTEMPTS=2
SLEEP_AFTER_RESTART=10          # seconds to wait before re‑checking status

# Helper: print timestamped messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

# 1) Examine kubelet logs for errors or warnings
log "Scanning ${KUBELET_UNIT} logs for errors/warnings (last ${LOG_LOOKBACK})..."
if journalctl -u "${KUBELET_UNIT}" --since="${LOG_LOOKBACK}" \
        | grep -iE "(error|warn)" > /tmp/k8s_log_issues.txt; then
    log "Found error/warning entries in kubelet logs:"
    cat /tmp/k8s_log_issues.txt
    rm -f /tmp/k8s_log_issues.txt
    exit 1
else
    log "No error or warning messages detected in recent logs."
fi
rm -f /tmp/k8s_log_issues.txt

# Determine the node name (use hostname by default)
NODE_NAME="$(hostname)"
log "Using node name: ${NODE_NAME}"

# 2) Query Kubernetes API for node status
log "Fetching node list via kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
    log "ERROR: kubectl not installed or not in PATH."
    exit 2
fi

# Capture node line (if any)
NODE_LINE=$(kubectl get nodes -o wide | awk -v n="${NODE_NAME}" '$1==n')
if [[ -z "$NODE_LINE" ]]; then
    log "Node '${NODE_NAME}' NOT found in kubectl output – possible connectivity issue."

    # 3) Verify the node has a usable IP address
    log "Checking network interfaces for a non‑loopback IP..."
    IP_ADDR=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | head -n1 || true)

    if [[ -z "$IP_ADDR" ]]; then
        log "ERROR: No global IPv4 address configured on this node."
        exit 3
    else
        log "Found IP address: $IP_ADDR"
        log "Please ensure this IP is reachable from the control plane."
        exit 4
    fi
else
    # Extract the STATUS column (usually second field)
    NODE_STATUS=$(echo "$NODE_LINE" | awk '{print $2}')
    log "Node status reported by Kubernetes: ${NODE_STATUS}"

    if [[ "$NODE_STATUS" == "Ready" ]]; then
        log "Node is healthy and ready. Nothing further required."
        exit 0
    else
        log "Node is not Ready (status: ${NODE_STATUS}). Attempting remediation..."

        # 4) Restart kubelet service
        ATTEMPT=0
        while (( ATTEMPT < MAX_RESTART_ATTEMPTS )); do
            ((ATTEMPT++))
            log "Restart attempt ${ATTEMPT}/${MAX_RESTART_ATTEMPTS}: systemctl restart ${KUBELET_UNIT}"
            if sudo systemctl restart "${KUBELET_UNIT}"; then
                log "Waiting ${SLEEP_AFTER_RESTART}s for kubelet to settle..."
                sleep "${SLEEP_AFTER_RESTART}"
                # Re‑query node status
                NEW_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
                if [[ "$NEW_STATUS" == "True" ]]; then
                    log "Node has recovered to Ready state after restart."
                    exit 0
                else
                    log "Node still not Ready after restart (Ready condition = ${NEW_STATUS})."
                fi
            else
                log "ERROR: Failed to restart ${KUBELET_UNIT}."
            fi
        done

        log "All remedial attempts exhausted. Manual investigation required."
        exit 5
    fi
fi