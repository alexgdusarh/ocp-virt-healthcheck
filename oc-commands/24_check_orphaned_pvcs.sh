#!/usr/bin/env bash
# Check: Orphaned PersistentVolumeClaims
#
# A PVC not currently mounted by any pod is NOT by itself a reliable
# orphan signal - CDI-managed VM disk PVCs are legitimately unmounted
# whenever the owning VM is stopped (confirmed via must-gather review:
# real CDI-managed PVCs carry ownerReferences to a DataVolume AND
# cdi.kubevirt.io/* annotations even while completely unmounted).
#
# The real orphan signal is a PVC whose owner no longer exists:
#   1. PVC carries CDI/KubeVirt labels (app.kubernetes.io/managed-by=
#      cdi-controller - confirmed consistently present on every real
#      CDI-managed PVC) but has ZERO ownerReferences - a CDI-managed
#      disk that lost its owner reference somehow.
#   2. PVC's ownerReference names a DataVolume or VirtualMachine that
#      does NOT currently exist in the cluster (the owner was deleted
#      but, on a Retain-reclaim-policy StorageClass, the PVC/PV was
#      left behind rather than cleaned up).
# Deliberately NOT flagging every unowned PVC cluster-wide - verified
# against real must-gather data that plenty of legitimate PVCs (the
# internal image registry's own storage, a backup agent's log volume)
# are never owned by anything; that's normal, not an orphan signal.
set -euo pipefail

echo "### StorageClasses: reclaim policy (Retain = PVCs are NOT auto-cleaned on delete) ###"
oc get storageclass -o json \
  | jq -r '["NAME","PROVISIONER","RECLAIMPOLICY"], (.items[] | [.metadata.name, .provisioner, (.reclaimPolicy // "Delete")]) | @tsv' \
  | column -t

echo
echo "### PVCs: ownerReferences present? (bare list for quick scan) ###"
oc get pvc -A -o json \
  | jq -r '["NAMESPACE","NAME","STATUS","STORAGECLASS","OWNERKIND","OWNERNAME"], (.items[] | [
      .metadata.namespace,
      .metadata.name,
      .status.phase,
      (.spec.storageClassName // "-"),
      ((.metadata.ownerReferences[0].kind) // "NONE"),
      ((.metadata.ownerReferences[0].name) // "NONE")
    ]) | @tsv' \
  | column -t

echo
echo "### CDI/KubeVirt-managed PVCs with NO ownerReference (lost their owner - likely orphaned) ###"
echo "# (not checking ALL unowned PVCs - plenty of legitimate PVCs, e.g. the internal"
echo "#  image registry's own storage, are never owned by anything)"
oc get pvc -A -o json \
  | jq -r '
      .items[]
      | select((.metadata.labels["app.kubernetes.io/managed-by"] // "") == "cdi-controller")
      | select((.metadata.ownerReferences // []) | length == 0)
      | "\(.metadata.namespace)/\(.metadata.name) (storageClass=\(.spec.storageClassName // "-"))"'

echo
echo "### Cross-check: PVCs owned by a DataVolume that no longer exists ###"
EXISTING_DVS=$(oc get datavolumes -A -o json | jq -c '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"]')
oc get pvc -A -o json \
  | jq -r --argjson dvs "$EXISTING_DVS" '
      .items[]
      | select((.metadata.ownerReferences // [])[]? | select(.kind == "DataVolume"))
      | . as $pvc
      | ($pvc.metadata.ownerReferences[] | select(.kind == "DataVolume") | .name) as $owner_name
      | ($pvc.metadata.namespace + "/" + $owner_name) as $ref
      | select(($dvs | index($ref)) == null)
      | "\($pvc.metadata.namespace)/\($pvc.metadata.name) - owning DataVolume \($owner_name) NOT FOUND"'

echo
echo "### Cross-check: PVCs owned by a VirtualMachine that no longer exists ###"
EXISTING_VMS=$(oc get vms -A -o json | jq -c '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"]')
oc get pvc -A -o json \
  | jq -r --argjson vms "$EXISTING_VMS" '
      .items[]
      | select((.metadata.ownerReferences // [])[]? | select(.kind == "VirtualMachine"))
      | . as $pvc
      | ($pvc.metadata.ownerReferences[] | select(.kind == "VirtualMachine") | .name) as $owner_name
      | ($pvc.metadata.namespace + "/" + $owner_name) as $ref
      | select(($vms | index($ref)) == null)
      | "\($pvc.metadata.namespace)/\($pvc.metadata.name) - owning VirtualMachine \($owner_name) NOT FOUND"'
