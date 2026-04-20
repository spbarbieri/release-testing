#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose common issues on a Kubernetes worker node.
# Steps:
#   1. Scan recent kubelet logs for errors or warnings.
#   2. If clean, verify node status via `kubectl get nodes`.
#   3. If node is not Ready, confirm the node has a valid IP address.
#   4. If networking looks fine but node is still unhealthy,
#      restart the kubelet service.
# ------------------------------------------------------------

# Configurable parameters
LOG_LOOKBACK="1h"               # How far back to search logs (compatible with journalctl)
KUBELET_UNIT="kubelet"
MAX_LOG_LINES=1000              # Limit displayed log lines when errors are found
IP_INTERFACE_EXCLUDE="lo"       # Interface(s) to ignore when checking IPs

# Helper: print timestamped messages
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

# Step 1 – Examine kubelet logs for errors or warnings
check_logs() {
    log_msg "Scanning ${KUBELET_UNIT} logs for errors/warnings (last ${LOG_LOOKBACK})..."
    # Capture matching lines; ignore case; treat both "error" and "warning"
    mapfile -t matches < <(
        journalctl -u "${KUBELET_UNIT}" --since="${LOG_LOOKBACK}" \
            | grep -Ei "(error|warning)" || true
    )
    if (( ${#matches[@]} > 0 )); then
        log_msg "Found ${#matches[@]} error/warning entries:"
        printf '%s\n' "${matches[@]:0:${MAX_LOG_LINES}}"
        if (( ${#matches[@]} > MAX_LOG_LINES )); then
            log_msg "... (${#matches[@]} total, truncated to ${MAX_LOG_LINES} lines)"
        fi
        exit 1
    else
        log_msg "No error or warning messages detected in recent logs."
    fi
}

# Step 2 – Verify node status via kubectl
verify_node_status() {
    local node_name
    node_name="$(hostname)"
    log_msg "Fetching node status for '${node_name}' via kubectl..."
    
    # Ensure kubectl is available
    if ! command -v kubectl >/dev/null 2>&1; then
        log_msg "ERROR: kubectl not found in PATH."
        exit 2
    fi
    
    # Get node line (CSV format for easier parsing)
    local node_line
    node_line=$(kubectl get nodes -o wide --no-headers | awk "\$1 == \"${node_name}\"")
    
    if [[ -z "$node_line" ]]; then
        log_msg "Node '${node_name}' not listed in kubectl output. It may be unreachable from the control plane."
        return 1
    fi
    
    # Extract STATUS column (second field)
    local status
    status=$(echo "$node_line" | awk '{print $2}')
    log_msg "Node status reported as: ${status}"
    
    if [[ "$status" == "Ready" ]]; then
        log_msg "Node is healthy (Ready). No further action required."
        exit 0
    else
        log_msg "Node is not Ready (status: ${status}). Proceeding with deeper diagnostics."
        return 0
    fi
}

# Step 3 – Confirm the node has a usable IP address
check_network_interface() {
    log_msg "Checking network interfaces for a non‑loopback IP address..."
    # List IPv4 addresses excluding loopback and excluded interfaces
    local ips
    ips=$(ip -4 addr show scope global | awk '/inet/ {print $2}' | cut -d/ -f1)
    
    if [[ -z "$ips" ]]; then
        log_msg "WARNING: No global IPv4 address found on this node."
        return 1
    else
        log_msg "Detected IP address(es): $ips"
        return 0
    fi
}

# Step 4 – Restart kubelet if node remains unhealthy
restart_kubelet() {
    log_msg "Attempting to restart the kubelet service..."
    if systemctl is-active --quiet "${KUBELET_UNIT}"; then
        sudo systemctl restart "${KUBELET_UNIT}"
        log_msg "kubelet restarted successfully."
    else
        log_msg "kubelet service is not active; starting it instead."
        sudo systemctl start "${KUBELET_UNIT}"
    fi
    
    # Give kubelet a moment to settle before rechecking status
    sleep 10
    log_msg "Re‑evaluating node status after kubelet restart..."
    verify_node_status || {
        log_msg "Node still not Ready after kubelet restart. Manual investigation required."
        exit 3
    }
}

# -------------------- Main Execution Flow --------------------
main() {
    check_logs
    if verify_node_status; then
        # Node listed but not Ready → continue diagnostics
        if ! check_network_interface; then
            log_msg "Network issue detected. Please resolve IP configuration before proceeding."
            exit 4
        fi
        restart_kubelet
    else
        # Node not listed at all → likely network/connectivity problem
        log_msg "Node appears unreachable from the control plane. Verify network routes, firewalls, and that the node can reach the API server."
        exit 5
    fi
}

main "$@