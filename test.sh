#!/usr/bin/env bash
#
# Incident response automation for the "nikhil" service SLO breach.
# Performs diagnostics, computes error‑budget burn, and optionally applies
# immediate mitigations (rollback, scaling, alert escalation).
#
# Prerequisites:
#   - curl, jq, promtool, kubectl, istioctl, amtool installed and configured.
#   - Access to the Prometheus, Alertmanager and monitoring endpoints defined below.
#

set -euo pipefail

#############################
# Configuration & Defaults #
#############################
SERVICE="${SERVICE:-nikhil}"                # Service name (can be overridden via env)
NAMESPACE="${NAMESPACE:-prod}"              # K8s namespace
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus.example.com}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://alertmanager.example.com}"
DEP_STATUS_URL="${DEP_STATUS_URL:-http://monitoring.example.com/api/dependency_status}"
TIME_WINDOW_SECONDS=$((30*24*60*60))        # 30 days
STEP_SECONDS=300                           # 5‑minute step for range queries
TARGET_ERROR_RATE=0.01                     # Target error rate (1 %)
BURN_THRESHOLD_PERCENT=1                  # Trigger mitigation when burn > 1 %
SEVERITY="${severity:-elevated}"           # Expected severity level (env var)

######################################
# Helper functions – logging & exit  #
######################################
log() {
    local lvl="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$lvl" "$*" >&2
}
die() { log "ERROR" "$*"; exit 1; }

###########################################
# 1️⃣ Query current SLO remaining metric   #
###########################################
query_slo_remaining() {
    local ts now
    now="$(date +%s)"
    log "INFO" "Querying SLO error‑budget remaining for ${SERVICE}..."
    promtool query instant "slo:error_budget_remaining{service=\"${SERVICE}\"}" --time="${now}"
}

####################################################
# 2️⃣ Pull raw error‑rate data for the last 30 days #
####################################################
fetch_error_rate_series() {
    local start end url
    start="$(date -d "-${TIME_WINDOW_SECONDS}s" +%s)"
    end="$(date +%s)"
    url="${PROMETHEUS_URL}/api/v1/query_range"
    log "INFO" "Fetching error‑rate series (last 30 days)..."
    curl -sG "${url}" \
        --data-urlencode "query=rate(http_requests_total{service=\"${SERVICE}\",code!~\"2..\"}[5m])" \
        --data-urlencode "start=${start}" \
        --data-urlencode "end=${end}" \
        --data-urlencode "step=${STEP_SECONDS}"
}

#####################################################################
# 3️⃣ Compute average error rate and burn rate over the time window #
#####################################################################
compute_burn_rate() {
    local json avg_err_rate burn_rate perc
    json="$(fetch_error_rate_series)"
    # Extract all sample values, ignore nulls
    avg_err_rate=$(echo "${json}" |
        jq -r '.data.result[].values[][1]' |
        awk '{ sum+=$1; cnt++ } END { if(cnt==0){print 0}else{printf "%.6f", sum/cnt} }')
    # Burn = (actual - target) * time_window_seconds
    burn_rate=$(awk -v act="${avg_err_rate}" -v tgt="${TARGET_ERROR_RATE}" -v win="${TIME_WINDOW_SECONDS}" \
                 'BEGIN{ diff=act-tgt; if(diff<0) diff=0; print diff*win }')
    perc=$(awk -v br="${burn_rate}" -v win="${TIME_WINDOW_SECONDS}" 'BEGIN{ printf "%.2f", (br/win)*100 }')
    log "INFO" "Average error rate: ${avg_err_rate}"
    log "INFO" "Error‑budget burn (% of window): ${perc}%"
    echo "${perc}"
}

#########################################
# 4️⃣ List recent ReplicaSets / releases #
#########################################
list_recent_releases() {
    log "INFO" "Listing recent ReplicaSets for ${SERVICE}..."
    kubectl get rs -n "${NAMESPACE}" "${SERVICE}"* -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{.metadata.annotations['deployment.kubernetes.io/revision']}{'\n'}{end}"
}

#########################################################
# 5️⃣ Correlate spikes – placeholder (manual inspection) #
#########################################################
correlate_spikes() {
    log "WARN" "Automatic correlation not implemented – please review the error‑rate graph alongside release timestamps."
}

#########################################
# 6️⃣ Inspect recent pod logs for errors #
#########################################
inspect_pod_logs() {
    log "INFO" "Scanning pod logs for common error patterns (last 24 h)..."
    kubectl logs -n "${NAMESPACE}" -l app="${SERVICE}" --since=24h 2>/dev/null |
        grep -iE "timeout|exception|500" || true
}

#########################################
# 7️⃣ Retrieve Istio proxy stats (if any) #
#########################################
fetch_istio_stats() {
    local pod
    pod=$(kubectl get pod -n "${NAMESPACE}" -l app="${SERVICE}" -o name | head -n1 || true)
    if [[ -z "${pod}" ]]; then
        log "INFO" "No pods found for Istio stats collection."
        return
    fi
    log "INFO" "Fetching Istio proxy stats for ${pod}..."
    istioctl proxy-config stats "${pod}" -n "${NAMESPACE}" 2>/dev/null || true
}

#########################################
# 8️⃣ Validate downstream dependencies   #
#########################################
check_downstream_deps() {
    log "INFO" "Checking downstream dependency status..."
    curl -s "${DEP_STATUS_URL}?service=${SERVICE}" | jq '.' || true
}

#########################################
# 9️⃣ Confirm alert silences             #
#########################################
list_alert_silences() {
    log "INFO" "Querying existing Alertmanager silences..."
    amtool silence query --alertmanager.url="${ALERTMANAGER_URL}" || true
}

#########################################
# 10️⃣ Immediate mitigation actions     #
#########################################
apply_mitigation() {
    local action_taken=false

    # Rollback latest Deployment if burn exceeds threshold
    if [[ "${burn_percent}" == *"."* ]] && (( $(awk "BEGIN {print (${burn_percent}>${BURN_THRESHOLD_PERCENT})}") )); then
        log "CRITICAL" "Burn > ${BURN_THRESHOLD_PERCENT}% – initiating rollback..."
        if kubectl rollout undo deployment/"${SERVICE}" -n "${NAMESPACE}"; then
            log "INFO" "Rollback successful."
            action_taken=true
        else
            log "ERROR" "Rollback failed."
        fi

        # Scale up replicas temporarily
        log "INFO" "Scaling up replicas to mitigate load..."
        if kubectl scale deployment/"${SERVICE}" --replicas=8 -n "${NAMESPACE}"; then
            log "INFO" "Scale operation succeeded."
            action_taken=true
        else
            log "ERROR" "Failed to scale deployment."
        fi

        # Escalate alert severity for next 24h
        log "INFO" "Creating high‑severity alert for next 24 h..."
        amtool alert add \
            --receiver=oncall-team \
            --severity=critical \
            "SLO breach imminent for ${SERVICE}" || true
        action_taken=true
    else
        log "INFO" "Burn within acceptable limits – no automatic mitigation applied."
    fi

    $action_taken && log "INFO" "Mitigation steps completed." || log "INFO" "No mitigation required."
}

#########################
# Main execution flow   #
#########################
main() {
    log "INFO" "=== Incident Response Runbook Start ==="

    # Step 1 – Current SLO metric
    query_slo_remaining || die "Failed to query SLO metric."

    # Step 2–3 – Error‑rate series & burn calculation
    burn_percent=$(compute_burn_rate)

    # Step 4 – Recent releases
    list_recent_releases || log "WARNING" "Could not retrieve ReplicaSet info."

    # Step 5 – Correlation (manual)
    correlate_spikes

    # Step 6 – Pod logs
    inspect_pod_logs

    # Step 7 – Istio stats
    fetch_istio_stats

    # Step 8 – Dependency health
    check_downstream_deps

    # Step 9 – Alert silences
    list_alert_silences

    # Step 10 – Conditional mitigation
    apply_mitigation

    log "INFO" "=== Incident Response Runbook End ==="
}

main "$@"