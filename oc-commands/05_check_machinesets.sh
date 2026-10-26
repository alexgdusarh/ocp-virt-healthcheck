#!/usr/bin/env bash
# Check: MachineSets (and backing Machines) status
#
# MachineSets are not always present (e.g. many bare-metal / UPI
# installs have no machine-api MachineSets). This script detects
# whether the API even has the resource/any instances before judging
# health, instead of assuming they must exist.
set -euo pipefail

echo "### MachineSets: do any exist? ###"
if ! oc get machinesets -n openshift-machine-api >/dev/null 2>&1; then
  echo "MachineSet API not present or no access (expected on many bare-metal installs)"
else
  COUNT=$(oc get machinesets -n openshift-machine-api -o json | jq '.items | length')
  if [ "$COUNT" -eq 0 ]; then
    echo "MachineSet API present, but 0 MachineSets found (expected on many bare-metal installs)"
  else
    echo "### MachineSets: desired vs current vs ready replicas ###"
    oc get machinesets -n openshift-machine-api -o json \
      | jq -r '
          ["NAME","DESIRED","CURRENT","READY","AVAILABLE"],
          (.items[] | [
            .metadata.name,
            (.spec.replicas|tostring),
            (.status.replicas|tostring),
            (.status.readyReplicas|tostring),
            (.status.availableReplicas|tostring)
          ])
          | @tsv' \
      | column -t

    echo
    echo "### MachineSets: ones NOT fully ready/available ###"
    oc get machinesets -n openshift-machine-api -o json \
      | jq -r '
          .items[]
          | select(.spec.replicas != .status.readyReplicas or .spec.replicas != .status.availableReplicas)
          | .metadata.name'

    echo
    echo "### Machines: phase per machine (should be Running) ###"
    oc get machines -n openshift-machine-api -o json \
      | jq -r '["NAME","PHASE","MACHINESET"], (.items[] | [.metadata.name, (.status.phase // "Unknown"), (.metadata.labels["machine.openshift.io/cluster-api-machineset"] // "none")]) | @tsv' \
      | column -t
  fi
fi
