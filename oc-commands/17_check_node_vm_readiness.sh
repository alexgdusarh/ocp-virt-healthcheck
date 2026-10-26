#!/usr/bin/env bash
# Check: Node readiness for VM scheduling (pre-workload)
#
# "kubevirt.io/schedulable=true" reflects virt-handler LIVENESS (a
# heartbeat), not proof that KVM is actually usable - there is a
# documented gap between the two (upstream kubevirt/kubevirt#8583).
# This check verifies BOTH signals, plus standard Node readiness and
# the KubeVirt-specific maintenance/drain taint, rather than trusting
# any single field.
set -euo pipefail

echo "### Nodes: Ready condition + SchedulingDisabled (cordon) ###"
oc get nodes -o json \
  | jq -r '
      ["NAME","READY","UNSCHEDULABLE"],
      (.items[] | [
        .metadata.name,
        ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"),
        (.spec.unschedulable // false | tostring)
      ])
      | @tsv' \
  | column -t

echo
echo "### Nodes: kubevirt.io/schedulable label (virt-handler heartbeat liveness) ###"
oc get nodes -o json \
  | jq -r '["NAME","SCHEDULABLE"], (.items[] | [.metadata.name, (.metadata.labels["kubevirt.io/schedulable"] // "MISSING")]) | @tsv' \
  | column -t

echo
echo "### Nodes: devices.kubevirt.io/kvm allocatable count (actual KVM device availability) ###"
oc get nodes -o json \
  | jq -r '["NAME","KVM_ALLOCATABLE"], (.items[] | [.metadata.name, (.status.allocatable["devices.kubevirt.io/kvm"] // "0")]) | @tsv' \
  | column -t

echo
echo "### Gap check: nodes labeled schedulable=true but with 0 (or missing) KVM devices ###"
oc get nodes -o json \
  | jq -r '
      .items[]
      | select((.metadata.labels["kubevirt.io/schedulable"] // "false") == "true")
      | select(((.status.allocatable["devices.kubevirt.io/kvm"] // "0") | tonumber) == 0)
      | .metadata.name'

echo
echo "### Nodes: kubevirt.io/drain taint (maintenance in progress via Node Maintenance Operator) ###"
oc get nodes -o json \
  | jq -r '.items[] | select((.spec.taints // []) | any(.key == "kubevirt.io/drain")) | .metadata.name'

echo
echo "### Summary: nodes NOT fully ready for VM scheduling (any of: NotReady, cordoned, not kubevirt-schedulable, 0 KVM devices, drain taint) ###"
oc get nodes -o json \
  | jq -r '
      .items[]
      | select(
          ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown") != "True"
          or (.spec.unschedulable // false)
          or ((.metadata.labels["kubevirt.io/schedulable"] // "false") != "true")
          or (((.status.allocatable["devices.kubevirt.io/kvm"] // "0") | tonumber) == 0)
          or ((.spec.taints // []) | any(.key == "kubevirt.io/drain"))
        )
      | .metadata.name'
