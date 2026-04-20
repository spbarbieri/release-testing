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
LOG_LOOKBACK="1h"               # How far back to search logs (compatible with journalctl)
KUBELET_UNIT="kubelet"
MAX_LOG_LINES=1000              # Limit output size when displaying logs

# Helper: print a header
header() {
    echo -e "\n=== $* ===\n"
}

# 1. Check kubelet logs for errors or warnings
header "Scanning kubelet logs for errors/warnings (last ${LOG_LOOKBACK})"

if command -v journalctl >/dev/null 2>&1; then
    LOG_OUTPUT=$(journalctl -u "${KUBELET_UNIT}" --since="${LOG_LOOKBACK}" \
        | grep -Ei "(error|warn)" || true)
else
    # Fallback to syslog if journalctl unavailable
    LOG_FILE="/var/log/kubelet.log"
    if [[ -f "${LOG_FILE}" ]]; then
        LOG_OUTPUT=$(grep -Ei "(error|warn)" "${LOG_FILE}" || true)
    else
        echo "Unable to locate kubelet logs."
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

# 2. Verify node status via kubectl
header "Checking node status with kubectl"

# Ensure kubectl is available
if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl command not found. Install/ configure kubectl first."
    exit 2
fi

NODE_NAME="$(hostname)"
# Get node line (format: NAME STATUS ... )
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

# 3. If node not reachable, verify network configuration
if [[ "${NODE_REACHABLE:-true}" = false ]]; then
    header "Verifying network interfaces on the node"
    ip addr show up primary scope global | awk '/inet /{print $2}'
    echo "Ensure the node has a routable IP address and can reach the control plane."
    exit 3
fi

# 4. Node reachable but unhealthy – attempt kubelet restart
header "Attempting to restart kubelet service"

if systemctl is-active --quiet "${KUBELET_UNIT}"; then
    echo "Restarting ${KUBELET_UNIT}..."
    sudo systemctl restart "${KUBELET_UNIT}"
    sleep 10  # give kubelet time to re-register
    echo "Rechecking node status after kubelet restart..."
    NEW_STATUS=$(kubectl get nodes -o jsonpath="{.items[?(@.metadata.name=='${NODE_NAME}')].status.conditions[?(@.type=='Ready')].status}")
    if [[ "${NEW_STATUS}" == "True" ]]; then
        echo "Node '${NODE_NAME}' is now Ready."
        exit 0
    else
        echo "Node remains not Ready after kubelet restart."
        exit 4
    fi
else
    echo "kubelet service is not active. Attempting to start it..."
    sudo systemctl start "${KUBELET_UNIT}"
    echo "Started kubelet. Re-run the script to verify status."
    exit 5
fi