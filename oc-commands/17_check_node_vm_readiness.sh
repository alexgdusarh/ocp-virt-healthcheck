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

# devices.kubevirt.io/kvm allocatable is a Kubernetes resource.Quantity,
# not a bare integer string - on some nodes it is serialized with a
# decimal/binary SI suffix (e.g. "1k" = 1000), which jq's tonumber
# cannot parse ("Invalid numeric literal"). This jq def strips and
# resolves the suffix before converting, per the documented
# resource.Quantity suffix table.
JQ_QUANTITY_DEF='
  def quantity_to_number:
    if type == "number" then .
    elif test("^[0-9]+$") then tonumber
    else
      (capture("^(?<num>[0-9.]+)(?<suf>[a-zA-Z]+)$")) as $c
      | ($c.num | tonumber) as $n
      | ($c.suf) as $s
      | ($n * (
          if $s == "n" then 0.000000001
          elif $s == "u" then 0.000001
          elif $s == "m" then 0.001
          elif $s == "k" or $s == "K" then 1000
          elif $s == "M" then 1000000
          elif $s == "G" then 1000000000
          elif $s == "Ki" then 1024
          elif $s == "Mi" then 1048576
          elif $s == "Gi" then 1073741824
          else error("unrecognized quantity suffix: " + $s)
          end
        ))
    end;
'

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
  | jq -r "$JQ_QUANTITY_DEF"'
      .items[]
      | select((.metadata.labels["kubevirt.io/schedulable"] // "false") == "true")
      | select(((.status.allocatable["devices.kubevirt.io/kvm"] // "0") | quantity_to_number) == 0)
      | .metadata.name'

echo
echo "### Nodes: kubevirt.io/drain taint (maintenance in progress via Node Maintenance Operator) ###"
oc get nodes -o json \
  | jq -r '.items[] | select((.spec.taints // []) | any(.key == "kubevirt.io/drain")) | .metadata.name'

echo
echo "### Summary: nodes NOT fully ready for VM scheduling (any of: NotReady, cordoned, not kubevirt-schedulable, 0 KVM devices, drain taint) ###"
oc get nodes -o json \
  | jq -r "$JQ_QUANTITY_DEF"'
      .items[]
      | select(
          ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown") != "True"
          or (.spec.unschedulable // false)
          or ((.metadata.labels["kubevirt.io/schedulable"] // "false") != "true")
          or (((.status.allocatable["devices.kubevirt.io/kvm"] // "0") | quantity_to_number) == 0)
          or ((.spec.taints // []) | any(.key == "kubevirt.io/drain"))
        )
      | .metadata.name'
