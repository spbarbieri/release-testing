#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1. Scan recent kubelet logs for errors or warnings.
#   2. If clean, verify node status via `kubectl get nodes`.
#   3. If node not reachable, confirm the node has a valid IP.
#   4. If node is reachable but still unhealthy, restart kubelet.
# ------------------------------------------------------------

# Configurable parameters
LOG_SINCE="1h"                # How far back to search logs (e.g., "30m", "2h")
KUBELET_UNIT="kubelet"
MAX_LOG_LINES=1000            # Limit displayed log lines when errors are found

# Helper: print a header
header() {
    echo -e "\n=== $* ===\n"
}

# Step 1: Examine kubelet logs for errors or warnings
header "Scanning kubelet logs for errors/warnings (last ${LOG_SINCE})"
if command -v journalctl >/dev/null 2>&1; then
    LOG_OUTPUT=$(journalctl -u "${KUBELET_UNIT}" --since="${LOG_SINCE}" \
                 | grep -Ei "(error|warn)" || true)
else
    # Fallback to syslog if journalctl unavailable
    LOG_FILE="/var/log/kubelet.log"
    if [[ -f "${LOG_FILE}" ]]; then
        LOG_OUTPUT=$(grep -Ei "(error|warn)" "${LOG_FILE}" || true)
    else
        LOG_OUTPUT=""
    fi
fi

if [[ -n "${LOG_OUTPUT}" ]]; then
    echo "Found error/warning entries in kubelet logs:"
    echo "${LOG_OUTPUT}" | tail -n "${MAX_LOG_LINES}"
    echo "Please investigate the above log entries before proceeding."
    exit 1
else
    echo "No error or warning messages detected in recent kubelet logs."
fi

# Step 2: Verify node status via kubectl
header "Checking node status with kubectl"
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not installed or not in PATH."
    exit 2
fi

NODE_NAME="$(hostname)"
# Retrieve node line (NAME STATUS ...) from kubectl output
NODE_LINE=$(kubectl get nodes -o wide | awk -v n="${NODE_NAME}" '$1==n')
if [[ -z "${NODE_LINE}" ]]; then
    echo "Node '${NODE_NAME}' not listed in 'kubectl get nodes'."
    NODE_REACHABLE=false
else
    NODE_STATUS=$(echo "${NODE_LINE}" | awk '{print $2}')
    echo "Node '${NODE_NAME}' reported status: ${NODE_STATUS}"
    if [[ "${NODE_STATUS}" == "Ready" ]]; then
        echo "Node is healthy. No further action required."
        exit 0
    else
        echo "Node status indicates a problem (${NODE_STATUS})."
        NODE_REACHABLE=true
    fi
fi

# Step 3: Verify network connectivity (IP assignment)
header "Verifying network interfaces and IP addresses"
IP_INFO=$(ip -brief addr show up primary scope global | awk '{print $1,$3}')
if [[ -z "${IP_INFO}" ]]; then
    echo "No active non‑loopback network interface with a global IP found."
    echo "Network configuration may be missing or down."
    exit 3
else
    echo "Active interfaces with IPs:"
    echo "${IP_INFO}"
fi

# Step 4: Attempt recovery by restarting kubelet
header "Attempting to recover node by restarting kubelet service"
if systemctl is-active --quiet "${KUBELET_UNIT}"; then
    echo "Restarting ${KUBELET_UNIT}..."
    sudo systemctl restart "${KUBELET_UNIT}"
    echo "Restart issued. Waiting briefly for kubelet to re‑register..."
    sleep 15
    # Re‑check node status after restart
    NEW_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || echo "Unknown")
    if [[ "${NEW_STATUS}" == "True" ]]; then
        echo "Node '${NODE_NAME}' is now Ready."
        exit 0
    else
        echo "Node still not Ready after kubelet restart (status=${NEW_STATUS})."
        exit 4
    fi
else
    echo "kubelet service is not active. Starting it..."
    sudo systemctl start "${KUBELET_UNIT}"
    echo "Service started. Please re‑run the script to verify health."
    exit 5
fi