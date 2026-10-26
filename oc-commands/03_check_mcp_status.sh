#!/usr/bin/env bash
# Check: MachineConfigPool (MCP) status
#
# Verifies every MCP has all its machineCount == readyMachineCount
# (no node stuck updating/degraded) and is not reporting Degraded=True.
set -euo pipefail

echo "### MachineConfigPools: quick table ###"
oc get mcp

echo
echo "### MachineConfigPools: machineCount vs readyMachineCount vs updatedMachineCount ###"
oc get mcp -o json \
  | jq -r '
      ["NAME","MACHINECOUNT","READY","UPDATED","DEGRADED"],
      (.items[] | [
        .metadata.name,
        (.status.machineCount|tostring),
        (.status.readyMachineCount|tostring),
        (.status.updatedMachineCount|tostring),
        (.status.conditions[]? | select(.type=="Degraded") | .status)
      ])
      | @tsv' \
  | column -t

echo
echo "### MachineConfigPools: pools NOT fully ready/updated or Degraded ###"
oc get mcp -o json \
  | jq -r '
      .items[]
      | select(
          .status.machineCount != .status.readyMachineCount
          or .status.machineCount != .status.updatedMachineCount
          or (.status.conditions[]? | select(.type=="Degraded") | .status) == "True"
        )
      | .metadata.name'
