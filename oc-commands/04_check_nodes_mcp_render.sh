#!/usr/bin/env bash
# Check: Nodes match their MachineConfigPool's rendered config
#
# Each node carries annotations showing which rendered MachineConfig it is
# currently running and which one it desires. Both should match each
# other (no pending/in-progress update) AND match the MCP's
# status.configuration.name for the pool that node belongs to.
set -euo pipefail

echo "### Step 1: per-node current vs desired rendered config + update state ###"
oc get nodes -o json \
  | jq -r '
      ["NODE","CURRENTCONFIG","DESIREDCONFIG","STATE","REASON"],
      (.items[] | [
        .metadata.name,
        (.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] // "none"),
        (.metadata.annotations["machineconfiguration.openshift.io/desiredConfig"] // "none"),
        (.metadata.annotations["machineconfiguration.openshift.io/state"] // "none"),
        (.metadata.annotations["machineconfiguration.openshift.io/reason"] // "-")
      ])
      | @tsv' \
  | column -t

echo
echo "### Step 2: nodes where current != desired (mid-update or stuck) ###"
oc get nodes -o json \
  | jq -r '
      .items[]
      | select(
          .metadata.annotations["machineconfiguration.openshift.io/currentConfig"]
          != .metadata.annotations["machineconfiguration.openshift.io/desiredConfig"]
        )
      | .metadata.name'

echo
echo "### Step 3: each MachineConfigPool's rendered config (source of truth) ###"
oc get mcp -o json \
  | jq -r '.items[] | [.metadata.name, .status.configuration.name] | @tsv' \
  | column -t -N POOL,RENDERED_CONFIG

echo
echo "### Step 4: node -> pool membership (via node-role labels) ###"
echo "# Repeat per pool; worker/master shown as examples:"
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns=NODE:.metadata.name,CURRENT:.metadata.annotations.'machineconfiguration\.openshift\.io/currentConfig'
oc get nodes -l node-role.kubernetes.io/master -o custom-columns=NODE:.metadata.name,CURRENT:.metadata.annotations.'machineconfiguration\.openshift\.io/currentConfig'

echo
echo "### Step 5: cross-check - for each pool, confirm its member nodes' currentConfig == pool's rendered config ###"
echo "# Example for 'worker' pool (swap selector/pool name as needed):"
POOL=worker
RENDERED=$(oc get mcp "$POOL" -o jsonpath='{.status.configuration.name}')
echo "Pool '$POOL' rendered config: $RENDERED"
oc get nodes -l "node-role.kubernetes.io/${POOL}" -o json \
  | jq -r --arg rendered "$RENDERED" '
      .items[]
      | select(.metadata.annotations["machineconfiguration.openshift.io/currentConfig"] != $rendered)
      | .metadata.name' \
  | awk 'BEGIN{f=0} {print "MISMATCH:", $0; f=1} END{if(f==0) print "All '"$POOL"' nodes match pool rendered config"}'
