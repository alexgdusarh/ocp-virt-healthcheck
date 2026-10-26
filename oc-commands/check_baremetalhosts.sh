#!/usr/bin/env bash
# Check: BareMetalHost presence and linkage to Machine
#
# BareMetalHosts (metal3) only exist on installer-provisioned
# bare-metal (IPI) clusters. This script detects whether the CRD/any
# instances exist, then shows each BMH's state and which Machine (if
# any) consumes it via spec.consumerRef.
set -euo pipefail

echo "### BareMetalHosts: do any exist? ###"
if ! oc get baremetalhosts -A >/dev/null 2>&1; then
  echo "BareMetalHost CRD not present or no access (expected on non-metal3 installs, e.g. UPI bare-metal or cloud)"
else
  COUNT=$(oc get baremetalhosts -A -o json | jq '.items | length')
  if [ "$COUNT" -eq 0 ]; then
    echo "BareMetalHost CRD present, but 0 BareMetalHosts found"
  else
    echo "### BareMetalHosts: state and power status ###"
    oc get baremetalhosts -A -o json \
      | jq -r '
          ["NAMESPACE","NAME","STATE","POWERED_ON","ERROR"],
          (.items[] | [
            .metadata.namespace,
            .metadata.name,
            (.status.provisioning.state // "unknown"),
            (.status.poweredOn|tostring),
            (.status.errorMessage // "-")
          ])
          | @tsv' \
      | column -t

    echo
    echo "### BareMetalHosts: consumerRef (linked Machine) per host ###"
    oc get baremetalhosts -A -o json \
      | jq -r '
          ["NAMESPACE","NAME","CONSUMER_MACHINE"],
          (.items[] | [
            .metadata.namespace,
            .metadata.name,
            (.spec.consumerRef.name // "NONE (unconsumed)")
          ])
          | @tsv' \
      | column -t

    echo
    echo "### BareMetalHosts: hosts with NO consumerRef (not backing any Machine) ###"
    oc get baremetalhosts -A -o json \
      | jq -r '.items[] | select(.spec.consumerRef == null) | "\(.metadata.namespace)/\(.metadata.name)"'

    echo
    echo "### Machines: provider/BMH linkage (cross-check from the other side) ###"
    oc get machines -n openshift-machine-api -o json \
      | jq -r '
          ["NAME","PHASE","PROVIDERID"],
          (.items[] | [.metadata.name, (.status.phase // "Unknown"), (.spec.providerID // "none")])
          | @tsv' \
      | column -t
  fi
fi
