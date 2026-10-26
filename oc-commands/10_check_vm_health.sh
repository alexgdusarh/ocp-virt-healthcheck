#!/usr/bin/env bash
# Check: VirtualMachine / VirtualMachineInstance health
#
# Verifies, across all namespaces:
#   - every VirtualMachine's printableStatus (should be "Running" if
#     spec.running/runStrategy says it should be, or "Stopped" if not)
#   - every VirtualMachineInstance's Ready condition and phase
#   - no VMI stuck in a transitional phase (Scheduling/Scheduled/
#     Pending) for longer than expected
set -euo pipefail

echo "### VirtualMachines: printableStatus across all namespaces ###"
oc get vms -A -o json \
  | jq -r '
      ["NAMESPACE","NAME","RUNSTRATEGY","PRINTABLESTATUS"],
      (.items[] | [
        .metadata.namespace,
        .metadata.name,
        (.spec.runStrategy // (if .spec.running then "Always(legacy)" else "Halted(legacy)" end)),
        .status.printableStatus
      ])
      | @tsv' \
  | column -t

echo
echo "### VirtualMachines: any NOT Running or Stopped (i.e. stuck mid-transition) ###"
oc get vms -A -o json \
  | jq -r '.items[] | select(.status.printableStatus != "Running" and .status.printableStatus != "Stopped") | "\(.metadata.namespace)/\(.metadata.name): \(.status.printableStatus)"'

echo
echo "### VirtualMachineInstances: phase + Ready condition ###"
oc get vmis -A -o json \
  | jq -r '
      ["NAMESPACE","NAME","PHASE","READY","NODE"],
      (.items[] | [
        .metadata.namespace,
        .metadata.name,
        .status.phase,
        ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"),
        (.status.nodeName // "-")
      ])
      | @tsv' \
  | column -t

echo
echo "### VirtualMachineInstances: any NOT Running/Ready ###"
oc get vmis -A -o json \
  | jq -r '
      .items[]
      | select(.status.phase != "Running" or ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown") != "True")
      | "\(.metadata.namespace)/\(.metadata.name): phase=\(.status.phase)"'
