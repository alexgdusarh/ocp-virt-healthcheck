#!/usr/bin/env bash
# Check: MTV (Migration Toolkit for Virtualization / Forklift) operator health
#
# MTV is a separate OLM operator (not part of OpenShift Virtualization
# itself) installed to migrate VMs INTO OpenShift Virtualization from
# external sources (vSphere, oVirt/RHV, OpenStack, OVA). Optional -
# absence is normal on a cluster that hasn't set up migrations yet.
#
# Verifies:
#   - mtv-operator CSV Succeeded (namespace: openshift-mtv)
#   - core Deployments (forklift-controller, forklift-api,
#     forklift-validation, etc.) fully ready
#   - every Provider's Ready/ConnectionTestSucceeded/InventoryCreated
#     conditions (the exact printcolumns MTV's own CRD exposes)
#   - every NetworkMap/StorageMap Ready condition
set -euo pipefail

NS="${MTV_NAMESPACE:-openshift-mtv}"

echo "### MTV presence: namespace + operator CRD ###"
if ! oc get project "$NS" >/dev/null 2>&1 && ! oc get crd providers.forklift.konveyor.io >/dev/null 2>&1; then
  echo "Namespace ${NS} and providers.forklift.konveyor.io CRD not found - MTV is not installed on this cluster"
  exit 0
fi

echo
echo "### mtv-operator CSV: phase ###"
oc get csv -n "$NS" -o json \
  | jq -r '.items[] | select(.metadata.name | test("^mtv-operator")) | [.metadata.name, .status.phase] | @tsv' \
  | awk 'BEGIN{print "CSV\tPHASE"} {print}'

echo
echo "### MTV Deployments: desired vs ready (namespace: ${NS}) ###"
echo "# (listing all Deployments in the namespace - component names can shift slightly by version)"
oc get deployment -n "$NS" -o json \
  | jq -r '["NAME","DESIRED","READY"], (.items[] | [.metadata.name, (.spec.replicas|tostring), (.status.readyReplicas // 0 | tostring)]) | @tsv' \
  | column -t

echo
echo "### Providers: Type / Status / Ready / Connected / Inventory (MTV's own CRD printcolumns) ###"
oc get providers.forklift.konveyor.io -n "$NS" -o json \
  | jq -r '
      ["NAME","TYPE","PHASE","READY","CONNECTED","INVENTORY"],
      (.items[] | [
        .metadata.name,
        (.spec.type // "-"),
        (.status.phase // "-"),
        ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown"),
        ((.status.conditions[]? | select(.type=="ConnectionTestSucceeded") | .status) // "Unknown"),
        ((.status.conditions[]? | select(.type=="InventoryCreated") | .status) // "Unknown")
      ])
      | @tsv' \
  | column -t

echo
echo "### Providers: critical-category conditions present (ConnectionAuthFailed, ConnectionTestFailed, SecretNotValid, UrlNotValid, ProviderTypeNotSupported, SettingsNotValid) ###"
oc get providers.forklift.konveyor.io -n "$NS" -o json \
  | jq -r '
      .items[]
      | .metadata.name as $name
      | (.status.conditions[]? | select(.type | IN("ConnectionAuthFailed","ConnectionTestFailed","SecretNotValid","UrlNotValid","ProviderTypeNotSupported","SettingsNotValid")) | select(.status=="True"))
      | "\($name): \(.type) (\(.reason // "-"))"'

echo
echo "### NetworkMaps / StorageMaps: Ready condition ###"
oc get networkmaps.forklift.konveyor.io -n "$NS" -o json \
  | jq -r '["NAME","READY"], (.items[] | [.metadata.name, ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown")]) | @tsv' \
  | column -t
oc get storagemaps.forklift.konveyor.io -n "$NS" -o json \
  | jq -r '["NAME","READY"], (.items[] | [.metadata.name, ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown")]) | @tsv' \
  | column -t

echo
echo "### Plans: Ready condition (migration plans configured) ###"
oc get plans.forklift.konveyor.io -n "$NS" -o json \
  | jq -r '["NAME","READY"], (.items[] | [.metadata.name, ((.status.conditions[]? | select(.type=="Ready") | .status) // "Unknown")]) | @tsv' \
  | column -t
