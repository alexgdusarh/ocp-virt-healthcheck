#!/usr/bin/env bash
# Check: SDN - OVN-Kubernetes (default OCP CNI)
#
# Verifies:
#   - cluster Network config reports networkType=OVNKubernetes
#   - the "network" ClusterOperator is Available/not Degraded
#   - ovnkube-node DaemonSet is fully ready (one pod per node)
#   - ovnkube-control-plane Deployment is fully ready
set -euo pipefail

NS="${OVNK_NAMESPACE:-openshift-ovn-kubernetes}"

echo "### Cluster Network config: networkType ###"
oc get network.config.openshift.io cluster -o jsonpath='{.spec.networkType}{"\n"}'

echo
echo "### network ClusterOperator: conditions ###"
oc get co network -o json \
  | jq -r '.status.conditions[] | [.type, .status, .reason] | @tsv' \
  | column -t -N TYPE,STATUS,REASON

echo
echo "### ovnkube-node DaemonSet: desired vs ready (namespace: ${NS}) ###"
oc get daemonset ovnkube-node -n "$NS" -o json \
  | jq -r '["DESIRED","CURRENT","READY"], [(.status.desiredNumberScheduled|tostring), (.status.currentNumberScheduled|tostring), (.status.numberReady|tostring)] | @tsv' \
  | column -t

echo
echo "### ovnkube-control-plane Deployment: desired vs ready ###"
oc get deployment ovnkube-control-plane -n "$NS" -o json \
  | jq -r '["DESIRED","READY","AVAILABLE"], [(.spec.replicas|tostring), (.status.readyReplicas // 0 | tostring), (.status.availableReplicas // 0 | tostring)] | @tsv' \
  | column -t

echo
echo "### ovnkube pods: any NOT Running/Ready (namespace: ${NS}) ###"
oc get pods -n "$NS" -o json \
  | jq -r '
      .items[]
      | select(.status.phase != "Running" or ([.status.containerStatuses[]?.ready] | all) == false)
      | [.metadata.name, .status.phase, ([.status.containerStatuses[]?.ready] | all | tostring)]
      | @tsv' \
  | awk 'BEGIN{print "NAME\tPHASE\tALL_CONTAINERS_READY"} {print}'
