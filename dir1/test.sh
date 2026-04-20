#!/bin/bash
set -euo pipefail

# ----------------------------------------------------------------------
# Script: diagnose_k8s_node.sh
# Purpose: Diagnose a Kubernetes worker node and attempt recovery if possible.
#
# Steps:
#   1. Scan kubelet logs for errors or warnings.
#   2. If clean, verify node status via `kubectl get nodes`.
#   3. If node is not reachable/Ready, confirm the node has a valid IP.
#   4. If the node is reachable but still NotReady, restart the kubelet.
# ----------------------------------------------------------------------

# ---------- Configuration ----------
# Number of recent log lines to inspect (adjust as needed)
LOG_LINES=500

# Time to wait after restarting kubelet before re‑checking status (seconds)
RESTART_WAIT=15

# ---------------------------------------------------------------

# Helper: print timestamped messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# 1️⃣ Check kubelet logs for errors or warnings
log "Scanning kubelet logs for errors/warnings..."
if command -v journalctl >/dev/null 2>&1; then
    LOG_OUTPUT=$(journalctl -u kubelet -n "${LOG_LINES}" 2>/dev/null || true)
else
    # Fallback to traditional logfile location
    LOG_FILE="/var/log/kubelet.log"
    if [[ -f "${LOG_FILE}" ]]; then
        LOG_OUTPUT=$(tail -n "${LOG_LINES}" "${LOG_FILE}")
    else
        LOG_OUTPUT=""
    fi
fi

ERRORS=$(printf '%s\n' "${LOG_OUTPUT}" | grep -iE '(error|warning)' || true)

if [[ -n "${ERRORS}" ]]; then
    log "⚠️  Errors or warnings detected in kubelet logs:"
    printf '%s\n' "${ERRORS}"
    exit 1
fi
log "✅ No errors or warnings found in recent kubelet logs."

# 2️⃣ Verify node status via kubectl
if ! command -v kubectl >/dev/null 2>&1; then
    log "❌ kubectl command not found. Install kubectl and configure access."
    exit 1
fi

NODE_NAME="$(hostname)"
log "Checking status of node '${NODE_NAME}' with kubectl..."
# Retrieve the Ready condition value (True/False/Unknown)
READY_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

if [[ -z "${READY_STATUS}" ]]; then
    log "❌ Node '${NODE_NAME}' not listed in kubectl output or unable to query."
    exit 1
fi

if [[ "${READY_STATUS}" == "True" ]]; then
    log "✅ Node '${NODE_NAME}' is Ready. No further action required."
    exit 0
fi

log "🔎 Node '${NODE_NAME}' is not Ready (Status=${READY_STATUS}). Proceeding with deeper checks."

# 3️⃣ Confirm network connectivity – ensure a non‑loopback IP exists
log "Inspecting network interfaces for a usable IP address..."
# List IPv4 addresses that are UP, not loopback, and have global scope
IP_ADDRESSES=$(ip -4 -brief addr show up primary scope global | awk '{print $3}')

if [[ -z "${IP_ADDRESSES}" ]]; then
    log "❌ No global IPv4 address detected on this node. Network configuration may be broken."
    exit 1
fi

log "✅ Detected IP address(es): ${IP_ADDRESSES}"

# Optional: ping the API server to double‑check reachability (skip if unknown)
API_SERVER="${KUBE_APISERVER:-$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)}"
if [[ -n "${API_SERVER}" ]]; then
    API_HOST=$(echo "${API_SERVER}" | sed -E 's~https?://([^:/]+).*~\1~')
    log "Pinging Kubernetes API server (${API_HOST})..."
    if ping -c 3 -W 2 "${API_HOST}" >/dev/null 2>&1; then
        log "✅ API server reachable."
    else
        log "⚠️  Unable to reach API server at ${API_HOST}. Verify firewall/routing."
    fi
fi

# 4️⃣ Restart kubelet if node is still in a bad condition
if command -v systemctl >/dev/null 2>&1; then
    log "Attempting to restart kubelet service..."
    sudo systemctl restart kubelet
    log "Waiting ${RESTART_WAIT}s for kubelet to settle..."
    sleep "${RESTART_WAIT}"
else
    log "❌ systemctl not available. Cannot restart kubelet automatically."
    exit 1
fi

# Re‑evaluate node status after restart
log "Re‑checking node status post‑restart..."
NEW_READY_STATUS=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

if [[ "${NEW_READY_STATUS}" == "True" ]]; then
    log "🎉 Success! Node '${NODE_NAME}' is now Ready."
    exit 0
else
    log "🚨 Node '${NODE_NAME}' remains NotReady (Status=${NEW_READY_STATUS}). Manual investigation required."
    exit 2
fi