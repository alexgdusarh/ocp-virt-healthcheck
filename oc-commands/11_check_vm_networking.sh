#!/usr/bin/env bash
# Check: VM networking
#
# Covers, in order:
#   1. NMState operator status (optional - may not be installed)
#   2. NodeNetworkConfigurationPolicy (NNCP) status (if NMState present)
#   3. Physical NICs per node via "oc debug node/<node>" + nmcli,
#      compared for name/count consistency across nodes of the same role
#   4. Dedicated/secondary networks (NNCP interfaces NOT the default
#      br-ex/ovs-cni OCP network) - these are what VM secondary
#      interfaces ride on
#   5. NetworkAttachmentDefinitions (Multus NADs)
#   6. VLAN cross-check: VLANs defined in NNCPs vs VLANs referenced by
#      NADs (localnet/vlan-tagged NADs), flagging mismatches either way
set -euo pipefail

echo "### 1. NMState operator: CSV phase ###"
oc get csv -A -o json \
  | jq -r '.items[] | select(.metadata.name | test("^kubernetes-nmstate-operator")) | [.metadata.namespace, .metadata.name, .status.phase] | @tsv' \
  | awk 'BEGIN{print "NAMESPACE\tCSV\tPHASE"} {print}'
echo "(if empty: NMState operator not installed - optional, secondary/VLAN networking may still be configured without it)"

echo
echo "### 2. NodeNetworkConfigurationPolicy (NNCP): status per policy ###"
if oc get nncp >/dev/null 2>&1; then
  oc get nncp -o json \
    | jq -r '
        ["NAME","AVAILABLE","DEGRADED"],
        (.items[] | [
          .metadata.name,
          ((.status.conditions[]? | select(.type=="Available") | .status) // "Unknown"),
          ((.status.conditions[]? | select(.type=="Degraded") | .status) // "Unknown")
        ])
        | @tsv' \
    | column -t
else
  echo "NNCP CRD not present or no access (NMState not installed)"
fi

echo
echo "### 3. Physical NICs per node (via oc debug + nmcli) ###"
echo "# Run per node; repeat for each node you need to compare:"
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $NODE ---"
  oc debug "node/${NODE}" --quiet -- chroot /host nmcli -t -f DEVICE,TYPE,STATE device status \
    | awk -F: '$2=="ethernet" {print $1, $3}'
done

echo
echo "### 4. Dedicated/secondary networks: NNCP interfaces that are NOT the default OCP network ###"
echo "# (br-ex and ovs-configuration-owned interfaces are the default OCP network; anything"
echo "#  else defined in an NNCP - e.g. a bond/bridge used for VM traffic - is a dedicated network)"
if oc get nncp >/dev/null 2>&1; then
  oc get nncp -o json \
    | jq -r '
        ["POLICY","IFACE_NAME","IFACE_TYPE","VLAN"],
        (.items[]
          | .metadata.name as $policy
          | (.spec.desiredState.interfaces // [])[]
          | select(.name != "br-ex")
          | [$policy, .name, .type, (.vlan.id // "-" | tostring)])
        | @tsv' \
    | column -t
else
  echo "NNCP CRD not present or no access"
fi

echo
echo "### 5. NetworkAttachmentDefinitions: across all namespaces ###"
oc get network-attachment-definitions -A -o json \
  | jq -r '["NAMESPACE","NAME","VLAN"], (.items[] | [.metadata.namespace, .metadata.name, ((.spec.config | fromjson? | .vlan) // "-" | tostring)]) | @tsv' \
  | column -t

echo
echo "### 5b. Cross-check: VMI network references with NO matching NAD ###"
NADS=$(oc get network-attachment-definitions -A -o json | jq -c '[.items[] | "\(.metadata.namespace)/\(.metadata.name)"]')
oc get vmis -A -o json \
  | jq -r --argjson nads "$NADS" '
      .items[]
      | .metadata.namespace as $ns
      | .metadata.name as $vmi
      | (.spec.networks // [])[]
      | select(.multus != null)
      | .multus.networkName as $ref
      | ($ref | if test("/") then . else ($ns + "/" + .) end) as $resolved
      | select(($nads | index($resolved)) == null)
      | "\($ns)/\($vmi): references missing NAD \($ref)"'

echo
echo "### 6. VLAN cross-check: NNCP-defined VLANs vs NAD-referenced VLANs ###"
echo "# NNCP VLANs (the VLAN is actually configured on a node interface):"
if oc get nncp >/dev/null 2>&1; then
  oc get nncp -o json | jq -r '[.items[] | (.spec.desiredState.interfaces // [])[] | select(.vlan.id != null) | .vlan.id] | unique | .[]'
else
  echo "(NNCP not present)"
fi
echo "# NAD-referenced VLANs (the VLAN a NetworkAttachmentDefinition expects to exist):"
oc get network-attachment-definitions -A -o json \
  | jq -r '[.items[] | (.spec.config | fromjson? | .vlan) // empty] | unique | .[]'
