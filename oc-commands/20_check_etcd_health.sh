#!/usr/bin/env bash
# Check: etcd health and defragmentation status
#
# Foundational cluster health - etcd backs the API server that every
# other check (and CNV/KubeVirt's own reconciliation) depends on.
#
# Verifies:
#   - etcd ClusterOperator conditions (Available/Progressing/Degraded)
#   - per-member health and status via etcdctl (member list, DB size,
#     whether each member considers itself healthy)
#   - DB size vs configured quota (the classic "etcd database space
#     exceeded" failure mode) - read straight from the member's own
#     dbSize/dbSizeInUse in `etcdctl endpoint status`, not Prometheus
#     (no reliably documented `oc get --raw` metrics path confirmed)
#   - disk (fsync) latency: `etcdctl check perf` (documented since
#     OCP 4.4+) plus the actual production p99 of
#     etcd_disk_wal_fsync_duration_seconds and
#     etcd_disk_backend_commit_duration_seconds read from the
#     cluster-monitoring Prometheus - these are etcd's own documented
#     SLO thresholds (p99 wal_fsync < 10ms, p99 backend_commit <
#     25ms); a slow disk causes missed heartbeats, request timeouts,
#     and leader loss, independent of anything `check perf`'s
#     synthetic load will show at the moment you happen to run it
set -euo pipefail

echo "### etcd ClusterOperator: conditions ###"
oc get co etcd -o json \
  | jq -r '.status.conditions[] | [.type, .status, .reason, .message] | @tsv' \
  | column -t -s $'\t' -N TYPE,STATUS,REASON,MESSAGE

echo
echo "### etcd pods: one per master, all should be Running/Ready ###"
oc get pods -n openshift-etcd -l app=etcd -o json \
  | jq -r '["NAME","PHASE","NODE"], (.items[] | [.metadata.name, .status.phase, (.spec.nodeName // "-")]) | @tsv' \
  | column -t

echo
echo "### etcdctl endpoint status: per-member DB size, quota, leader ###"
ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd --field-selector="status.phase==Running" -o jsonpath='{.items[0].metadata.name}')
oc exec -n openshift-etcd -c etcd "$ETCD_POD" -- etcdctl endpoint status --cluster -w table

echo
echo "### etcdctl endpoint health: per-member health ###"
oc exec -n openshift-etcd -c etcd "$ETCD_POD" -- etcdctl endpoint health --cluster

echo
echo "### Configured quota (from pod env, no etcdctl parsing needed) ###"
oc get pod -n openshift-etcd "$ETCD_POD" -o json \
  | jq -r '.spec.containers[] | select(.name=="etcd") | .env[]? | select(.name=="ETCD_QUOTA_BACKEND_BYTES") | "\(.name)=\(.value)"'

echo
echo "### etcdctl check perf: synthetic disk/fsync latency benchmark ###"
echo "# Documented since OCP 4.4+ (https://access.redhat.com/solutions/4885641)."
echo "# Pass criteria printed by the tool itself; it compares the observed p99"
echo "# fsync latency against etcd's own 10ms budget. Runs a real write load"
echo "# against this member's actual disk - takes ~15-60s depending on --load."
oc exec -n openshift-etcd -c etcd "$ETCD_POD" -- etcdctl check perf --load="s" \
  || echo "(etcdctl check perf failed or is unavailable on this build - see production p99 query below instead)"

echo
echo "### Production disk latency: actual p99 wal_fsync / backend_commit (last 1h) ###"
echo "# etcd's documented SLO: p99 wal_fsync_duration_seconds < 10ms,"
echo "# p99 backend_commit_duration_seconds < 25ms. Unlike 'check perf' above"
echo "# (a one-off synthetic benchmark), this is the real latency etcd has"
echo "# actually been experiencing under production load."
TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=5m 2>/dev/null || true)
THANOS_HOST=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "$TOKEN" ] && [ -n "$THANOS_HOST" ]; then
  for METRIC in etcd_disk_wal_fsync_duration_seconds_bucket etcd_disk_backend_commit_duration_seconds_bucket; do
    echo "--- p99 ${METRIC%_bucket} (seconds) ---"
    curl -s -k -H "Authorization: Bearer ${TOKEN}" \
      --data-urlencode "query=histogram_quantile(0.99, sum(rate(${METRIC}[1h])) by (le, pod))" \
      "https://${THANOS_HOST}/api/v1/query" \
      | jq -r '.data.result[]? | "\(.metric.pod // "unknown"): \(.value[1])s"' \
      || echo "(query failed)"
  done
else
  echo "(could not obtain a Prometheus token or route - skipping; 'etcdctl check perf' above is the fallback signal)"
fi
