#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1. Scan recent kubelet logs for errors or warnings.
#   2. If clean, verify node status via `kubectl get nodes`.
#   3. If node is not Ready, confirm the node has a valid IP address.
#   4. If networking looks fine but node is still unhealthy, restart kubelet.
# ------------------------------------------------------------

LOG_TIMEFRAME="1h"               # How far back to search logs (e.g., 1h, 30m)
KUBELET_UNIT="kubelet"
NODE_NAME="$(hostname)"
TMP_LOG="/tmp/kubelet_recent.log"

# Function: Print a header
header() {
    echo -e "\n=== $* ===\n"
}

# Step 1 – Gather recent kubelet logs and look for errors/warnings
header "Collecting recent kubelet logs ($LOG_TIMEFRAME)..."
if ! command -v journalctl >/dev/null 2>&1; then
    echo "Error: journalctl not available on this system."
    exit 1
fi

journalctl -u "$KUBELET_UNIT" --since "-$LOG_TIMEFRAME" >"$TMP_LOG"

ERRORS=$(grep -Ei "(error|failed|panic)" "$TMP_LOG" || true)
WARNINGS=$(grep -Ei "(warn|warning)" "$TMP_LOG" || true)

if [[ -n "$ERRORS" ]] || [[ -n "$WARNINGS" ]]; then
    echo "Found issues in kubelet logs:"
    [[ -n "$ERRORS" ]] && { echo -e "\n--- Errors ---"; echo "$ERRORS"; }
    [[ -n "$WARNINGS" ]] && { echo -e "\n--- Warnings ---"; echo "$WARNINGS"; }
    echo "Please address the above log entries before proceeding."
    rm -f "$TMP_LOG"
    exit 0
else
    echo "No errors or warnings detected in recent kubelet logs."
fi
rm -f "$TMP_LOG"

# Step 2 – Verify node status via kubectl
header "Checking node status with kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not installed or not in PATH."
    exit 1
fi

# Capture the line corresponding to this node
NODE_LINE=$(kubectl get nodes -o wide | awk -v n="$NODE_NAME" '$1==n')
if [[ -z "$NODE_LINE" ]]; then
    echo "Node \"$NODE_NAME\" not listed in kubectl output. It may be unreachable from the control plane."
    NODE_REACHABLE=false
else
    NODE_STATUS=$(echo "$NODE_LINE" | awk '{print $2}')
    echo "Node \"$NODE_NAME\" reported status: $NODE_STATUS"
    NODE_REACHABLE=true
fi

# Helper: Determine if node is considered healthy
is_node_ready() {
    [[ "$NODE_STATUS" == "Ready" ]]
}

# Step 3 – Network verification (only if node not reachable or not Ready)
if ! $NODE_REACHABLE || ! is_node_ready; then
    header "Verifying network configuration on the node..."

    # List non‑loopback interfaces with an IPv4 address
    IPV4_ADDRS=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1)

    if [[ -z "$IPV4_ADDRS" ]]; then
        echo "No global IPv4 address found on this node. Please configure networking."
        exit 1
    else
        echo "Detected IPv4 addresses:"
        echo "$IPV4_ADDRS"
    fi

    # If node was listed but not Ready, we consider it reachable but unhealthy
    if $NODE_REACHABLE && ! is_node_ready; then
        echo "Node is reachable (has IP) but reports a non‑Ready status."
        RESTART_NEEDED=true
    else
        echo "Node appears unreachable from the control plane. Check firewall rules, API server endpoint, and node registration."
        exit 1
    fi
else
    echo "Node is Ready and reachable. No further action required."
    exit 0
fi

# Step 4 – Restart kubelet if needed
if [[ "${RESTART_NEEDED:-false}" == true ]]; then
    header "Attempting to recover node by restarting kubelet service..."
    if ! command -v systemctl >/dev/null 2>&1; then
        echo "Error: systemctl not available; cannot manage services."
        exit 1
    fi

    sudo systemctl restart "$KUBELET_UNIT"
    echo "kubelet service restarted. Waiting briefly for status to settle..."
    sleep 10

    # Re‑check node status after restart
    NEW_STATUS=$(kubectl get nodes -o wide | awk -v n="$NODE_NAME" '$1==n {print $2}')
    echo "Post‑restart node status: ${NEW_STATUS:-unknown}"
    if [[ "$NEW_STATUS" == "Ready" ]]; then
        echo "Node recovered successfully."
        exit 0
    else
        echo "Node remains in a non‑Ready state. Further investigation required."
        exit 1
    fi
fi