#!/usr/bin/env bash
# Check: StorageClass + CDI (Containerized Data Importer) readiness
#
# VMs can't boot/clone/import disks without working storage + CDI.
# Verifies:
#   - at least one StorageClass exists, and which one is default
#   - CDI CR reports Available=True/Degraded=False
#   - cdi-* Deployments (apiserver, controller, deployment,
#     uploadproxy) are fully ready
#   - no DataVolume is stuck in a non-Succeeded/non-WaitForFirstConsumer
#     phase (e.g. ImportInProgress for a long time, or Failed)
set -euo pipefail

echo "### StorageClasses (default marked with *) ###"
oc get storageclass -o json \
  | jq -r '
      ["NAME","PROVISIONER","DEFAULT","VOLUMEBINDINGMODE"],
      (.items[] | [
        .metadata.name,
        .provisioner,
        ((.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false")),
        (.volumeBindingMode // "Immediate")
      ])
      | @tsv' \
  | column -t

echo
echo "### CDI CR: conditions ###"
oc get cdi -o json \
  | jq -r '.items[0].status.conditions[] | [.type, .status, .reason] | @tsv' \
  | column -t -N TYPE,STATUS,REASON

echo
echo "### CDI Deployments: desired vs ready ###"
oc get deployment -n openshift-cnv -l 'cdi.kubevirt.io' -o json \
  | jq -r '
      ["NAME","DESIRED","READY","AVAILABLE"],
      (.items[] | [.metadata.name, (.spec.replicas|tostring), (.status.readyReplicas // 0 | tostring), (.status.availableReplicas // 0 | tostring)])
      | @tsv' \
  | column -t

echo
echo "### DataVolumes: any stuck/failed across all namespaces ###"
oc get datavolumes -A -o json \
  | jq -r '
      ["NAMESPACE","NAME","PHASE","PROGRESS"],
      (.items[]
        | select(.status.phase != "Succeeded" and .status.phase != "WaitForFirstConsumer")
        | [.metadata.namespace, .metadata.name, .status.phase, (.status.progress // "-")])
      | @tsv' \
  | column -t
