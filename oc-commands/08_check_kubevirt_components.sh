#!/usr/bin/env bash
# Check: KubeVirt CR status + virt-handler/virt-api/virt-controller pods
#
# Verifies the core OCP-Virt runtime components (not just the operator
# from check 07): the KubeVirt CR's own condition set, and that every
# virt-handler (DaemonSet, one per node), virt-api, and virt-controller
# pod is Running and Ready.
set -euo pipefail

NS="${CNV_NAMESPACE:-openshift-cnv}"

echo "### KubeVirt CR: conditions ###"
oc get kubevirt -n "$NS" -o json \
  | jq -r '.items[0].status.conditions[] | [.type, .status, .reason] | @tsv' \
  | column -t -N TYPE,STATUS,REASON

echo
echo "### KubeVirt CR: observed/target version ###"
oc get kubevirt -n "$NS" -o json \
  | jq -r '.items[0].status | "observedKubeVirtVersion: \(.observedKubeVirtVersion // "unknown")  targetKubeVirtVersion: \(.targetKubeVirtVersion // "unknown")"'

echo
echo "### virt-api / virt-controller / virt-operator Deployments: desired vs ready ###"
oc get deployment -n "$NS" -l 'kubevirt.io' -o json \
  | jq -r '
      ["NAME","DESIRED","READY","AVAILABLE"],
      (.items[] | [.metadata.name, (.spec.replicas|tostring), (.status.readyReplicas // 0 | tostring), (.status.availableReplicas // 0 | tostring)])
      | @tsv' \
  | column -t

echo
echo "### virt-handler DaemonSet: desired vs ready (one per schedulable node) ###"
oc get daemonset virt-handler -n "$NS" -o json \
  | jq -r '["DESIRED","CURRENT","READY"], [(.status.desiredNumberScheduled|tostring), (.status.currentNumberScheduled|tostring), (.status.numberReady|tostring)] | @tsv' \
  | column -t

echo
echo "### Pods: any virt-* pod NOT Running/Ready ###"
oc get pods -n "$NS" -l 'kubevirt.io' -o json \
  | jq -r '
      .items[]
      | select(.status.phase != "Running" or ([.status.containerStatuses[]?.ready] | all) == false)
      | [.metadata.name, .status.phase, ([.status.containerStatuses[]?.ready] | all | tostring)]
      | @tsv' \
  | awk 'BEGIN{print "NAME\tPHASE\tALL_CONTAINERS_READY"} {print}'
