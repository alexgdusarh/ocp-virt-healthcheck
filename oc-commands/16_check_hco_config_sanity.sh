#!/usr/bin/env bash
# Check: HyperConverged CR config sanity (pre-workload)
#
# Pure configuration review - no VMs required. Flags genuinely risky
# non-default settings in the HyperConverged CR, not just unusual ones.
#
# HCO's OWN defaults (hco.kubevirt.io/v1beta1, NOT upstream raw
# KubeVirt's defaults, which differ):
#   liveMigrationConfig: completionTimeoutPerGiB=20, parallelMigrationsPerCluster=5,
#     parallelOutboundMigrationsPerNode=1, progressTimeout=150,
#     allowAutoConverge=false, allowPostCopy=false
#   workloadUpdateStrategy: workloadUpdateMethods=["LiveMigrate"],
#     batchEvictionSize=10, batchEvictionInterval=1m0s
# Most individually-named featureGates from older docs (withHostPassthroughCPU,
# disableMDevConfiguration, persistentReservation, autoResourceLimits, etc.)
# are now deprecated no-ops in current HCO - this script flags them as
# stale/ignorable rather than risky, and focuses on what's still live.
set -euo pipefail

NS="${CNV_NAMESPACE:-openshift-cnv}"

echo "### liveMigrationConfig: full value ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o jsonpath='{.spec.liveMigrationConfig}{"\n"}'

echo
echo "### liveMigrationConfig: risk checks ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o json | jq -r '
  (.spec.liveMigrationConfig // {}) as $lm
  | if ($lm.parallelMigrationsPerCluster == 0) then "RISK: parallelMigrationsPerCluster=0 - live migration is effectively DISABLED cluster-wide" else empty end,
    if ($lm.parallelOutboundMigrationsPerNode == 0) then "RISK: parallelOutboundMigrationsPerNode=0 - no node can initiate outbound migrations" else empty end,
    if ($lm.completionTimeoutPerGiB == 0) then "RISK: completionTimeoutPerGiB=0 - migrations will be judged non-convergent almost immediately" else empty end,
    if (($lm.allowWorkloadDisruption // false) == true and ($lm.allowPostCopy // false) == false) then "NOTE: allowWorkloadDisruption=true with allowPostCopy=false - a non-converging migration will PAUSE the VM instead of being cancelled" else empty end
'

echo
echo "### workloadUpdateStrategy: full value ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o jsonpath='{.spec.workloadUpdateStrategy}{"\n"}'

echo
echo "### workloadUpdateStrategy: risk checks ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o json | jq -r '
  (.spec.workloadUpdateStrategy.workloadUpdateMethods // ["LiveMigrate"]) as $methods
  | if ($methods | index("Evict")) and (($methods | index("LiveMigrate")) | not) then
      "RISK: workloadUpdateMethods=[Evict] without LiveMigrate - VMs will be hard-stopped (not migrated) during every KubeVirt component update"
    elif ($methods | index("Evict")) then
      "NOTE: Evict present alongside LiveMigrate - used as fallback for non-migratable VMs, each such VM WILL be hard-stopped during updates"
    else empty end
'

echo
echo "### featureGates: full value (most older named gates are now deprecated no-ops - see script header) ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o jsonpath='{.spec.featureGates}{"\n"}'

echo
echo "### defaultCPUModel ###"
CPUMODEL=$(oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o jsonpath='{.spec.defaultCPUModel}')
if [ -z "$CPUMODEL" ]; then
  echo "defaultCPUModel: unset (effective default: host-model)"
else
  echo "defaultCPUModel: $CPUMODEL"
fi

echo
echo "### Node CPU model diversity (relevant to defaultCPUModel risk) ###"
echo "# host-model VMs can only migrate to nodes with a matching/compatible CPU model."
echo "# If this cluster has more than one distinct CPU model, an unset defaultCPUModel is a real risk."
oc get nodes -o json | jq -r '[.items[].metadata.labels | to_entries[] | select(.key | startswith("cpu-model.node.kubevirt.io/")) | .key | sub("cpu-model.node.kubevirt.io/"; "")] | unique | .[]' 2>/dev/null || echo "(no cpu-model.node.kubevirt.io/* labels found - virt-handler may not have reported yet)"

echo
echo "### permittedHostDevices: full value ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o jsonpath='{.spec.permittedHostDevices}{"\n"}'
echo "# NOTE: to remove an entry, set disabled:true - do NOT delete it from the array, HCO will re-add it on reconcile."
echo "# externalResourceProvider:true entries depend on an external device plugin (e.g. NVIDIA GPU Operator) being healthy - verify it's actually running."
