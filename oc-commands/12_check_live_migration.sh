#!/usr/bin/env bash
# Check: Live migration readiness
#
# Verifies:
#   - no VirtualMachineInstanceMigration is stuck/failed (recent history
#     + any currently in-flight)
#   - no running VMI has evictionStrategy=LiveMigrate (or the cluster-
#     wide default requires it) while using a non-migratable volume
#     type (hostPath / local PVC), which would make eviction impossible
#   - KubeVirt's cluster-wide liveMigrationConfig (informational)
set -euo pipefail

echo "### VirtualMachineInstanceMigrations: recent/in-flight, phase ###"
oc get vmim -A -o json \
  | jq -r '
      ["NAMESPACE","NAME","VMI","PHASE"],
      (.items[] | [.metadata.namespace, .metadata.name, .spec.vmiName, .status.phase])
      | @tsv' \
  | column -t

echo
echo "### VirtualMachineInstanceMigrations: any Failed ###"
oc get vmim -A -o json \
  | jq -r '.items[] | select(.status.phase == "Failed") | "\(.metadata.namespace)/\(.metadata.name): vmi=\(.spec.vmiName) phase=\(.status.phase)"'

echo
echo "### VirtualMachineInstanceMigrations: currently in-flight (informational, not a failure by itself) ###"
oc get vmim -A -o json \
  | jq -r '.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | "\(.metadata.namespace)/\(.metadata.name): vmi=\(.spec.vmiName) phase=\(.status.phase)"'

echo
echo "### VMIs: evictionStrategy + volume types (to spot non-migratable VMIs that need eviction) ###"
oc get vmis -A -o json \
  | jq -r '
      ["NAMESPACE","VMI","EVICTIONSTRATEGY","NODE"],
      (.items[] | [.metadata.namespace, .metadata.name, (.spec.evictionStrategy // "ClusterDefault"), (.status.nodeName // "-")])
      | @tsv' \
  | column -t

echo
echo "### VMIs: with evictionStrategy=LiveMigrate (or inherited) that use hostPath/local volumes (NOT migratable) ###"
oc get vmis -A -o json \
  | jq -r '
      .items[]
      | select((.spec.evictionStrategy // "LiveMigrate") == "LiveMigrate")
      | .metadata.namespace as $ns | .metadata.name as $vmi
      | (.spec.volumes // [])[]
      | select(.hostDisk != null or (.persistentVolumeClaim != null and (.persistentVolumeClaim.claimName | test("local") )))
      | "\($ns)/\($vmi): non-migratable volume \(.name)"'

echo
echo "### KubeVirt cluster-wide liveMigrationConfig (informational) ###"
oc get kubevirt -n "${CNV_NAMESPACE:-openshift-cnv}" -o json \
  | jq -r '.items[0].spec.configuration.migrations // {}'
