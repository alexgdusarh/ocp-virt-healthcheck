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
