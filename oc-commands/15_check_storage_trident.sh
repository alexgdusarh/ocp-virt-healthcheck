#!/usr/bin/env bash
# Check: Storage - NetApp Trident CSI / ONTAP (basic)
#
# Scope note: Trident/ONTAP is a third-party component. This check
# covers how it interacts with OpenShift/OCP-Virt (is it installed,
# is it reporting healthy, can VMs actually provision/migrate on it) -
# not a deep dive into Trident/ONTAP internals, which is NetApp's own
# support surface.
#
# Verifies:
#   - TridentOrchestrator install status
#   - trident-controller Deployment + trident-csi DaemonSet readiness
#   - TridentBackend / TridentBackendConfig status (NOTE: NetApp/trident
#     issues #543 and #836 document backends/volumes sometimes
#     reporting "online" when they are not fully functional - treat
#     this status as a strong signal, not absolute proof)
#   - StorageClasses using the Trident provisioner, and whether any of
#     them are SAN-protocol (iSCSI/FC) with volumeMode Filesystem +
#     ReadWriteMany - a known non-functional-for-live-migration
#     combination even though Kubernetes accepts it
set -euo pipefail

NS="${TRIDENT_NAMESPACE:-trident}"

echo "### Trident presence: TridentOrchestrator CRD ###"
if ! oc get crd tridentorchestrators.trident.netapp.io >/dev/null 2>&1; then
  echo "tridentorchestrators.trident.netapp.io CRD not found - Trident is not installed on this cluster"
  exit 0
fi

echo
echo "### TridentOrchestrator: install status ###"
oc get torc -o json \
  | jq -r '.items[] | [.metadata.name, .status.status, (.status.version // "unknown")] | @tsv' \
  | awk 'BEGIN{print "NAME\tSTATUS\tVERSION"} {print}'

echo
echo "### trident-controller Deployment + trident-csi DaemonSet (namespace: ${NS}) ###"
echo "# (listing all Deployments/DaemonSets in the namespace - label names vary by install method/version)"
oc get deployment -n "$NS" -o json \
  | jq -r '["NAME","DESIRED","READY"], (.items[] | [.metadata.name, (.spec.replicas|tostring), (.status.readyReplicas // 0 | tostring)]) | @tsv' \
  | column -t
oc get daemonset -n "$NS" -o json \
  | jq -r '["NAME","DESIRED","READY"], (.items[] | [.metadata.name, (.status.desiredNumberScheduled|tostring), (.status.numberReady|tostring)]) | @tsv' \
  | column -t

echo
echo "### TridentBackend: state (NOTE: known false-positive risk - see NetApp/trident#543, #836) ###"
oc get tbe -n "$NS" -o json \
  | jq -r '["NAME","BACKEND_NAME","STATE","ONLINE"], (.items[] | [.metadata.name, (.backendName // "-"), .state, (.online|tostring)]) | @tsv' \
  | column -t

echo
echo "### TridentBackendConfig: lastOperationStatus ###"
oc get tbc -n "$NS" -o json \
  | jq -r '["NAME","PHASE","LASTOPSTATUS"], (.items[] | [.metadata.name, (.status.phase // "-"), (.status.lastOperationStatus // "-")]) | @tsv' \
  | column -t

echo
echo "### StorageClasses using the Trident CSI provisioner ###"
oc get storageclass -o json \
  | jq -r '["NAME","BACKENDTYPE_PARAM","VOLUMEBINDINGMODE"], (.items[] | select(.provisioner == "csi.trident.netapp.io") | [.metadata.name, (.parameters.backendType // .parameters.storagePools // "-" | tostring), (.volumeBindingMode // "Immediate")]) | @tsv' \
  | column -t

echo
echo "### Known gotcha check: SAN-backed StorageClasses that look RWX-capable but use volumeMode=Filesystem ###"
echo "# (ontap-san/ontap-san-economy only support RWX when volumeMode=Block; Filesystem mode will accept"
echo "#  the StorageClass/PVC definition but will NOT actually support live migration correctly)"
oc get storageclass -o json \
  | jq -r '.items[] | select(.provisioner == "csi.trident.netapp.io") | select((.parameters.backendType // "") | test("san")) | .metadata.name'
echo "# For any StorageClass listed above, check PVCs using it for volumeMode and accessModes:"
echo "oc get pvc -A -o json | jq -r '.items[] | select(.spec.storageClassName==\"<name>\") | [.metadata.namespace, .metadata.name, .spec.volumeMode, (.spec.accessModes|join(\",\"))] | @tsv'"
