#!/usr/bin/env bash
# Check: VLAN trunk reconciliation (dedicated bond, many VLANs/NADs)
#
# Two distinct VLAN provisioning mechanisms are both seen in the
# field, and this script auto-detects which one a cluster uses
# (confirmed live + verified against real must-gather data from a
# cluster running mechanism B - 62 real NADs/CUDNs, 2 physical
# networks phys-bond1/phys-bond2):
#
#  (A) NMState/NNCP-managed VLAN sub-interfaces on a dedicated bond,
#      with manually-created NADs pointing at them (seen: one
#      active-backup bond, 59 VLANs, 59 NADs). NMState has NO
#      trunk-list field at the bond/bridge level - the "trunk" is
#      whatever set of NNCP type:vlan sub-interfaces (vlan.base-iface
#      == <bond>, vlan.id == N) actually exist, built by enumeration.
#
#  (B) OVN-Kubernetes ClusterUserDefinedNetwork (CUDN), localnet
#      topology. The CUDN OWNS and GENERATES its NAD directly (NAD
#      has an ownerReference to the CUDN) - there is no separate NNCP
#      trunk list to reconcile against; the "physical network" is
#      spec.network.localnet.physicalNetworkName (the OVN mapping
#      name, not literally a bond device name) and the VLAN ID is
#      spec.network.localnet.vlan.access.id. Confirmed live: multiple
#      physicalNetworkName values can coexist on one cluster (seen:
#      phys-bond1 and phys-bond2), so uniqueness is scoped PER
#      physicalNetworkName, not cluster-wide.
#
# Mechanism A verifies:
#   1. Duplicate VLAN IDs across NADs (copy-paste risk at this scale)
#   2. Every NAD's VLAN ID has a matching NNCP vlan sub-interface on
#      the bond (i.e. is actually trunked, not just referenced by a NAD)
#   3. Bond member link/active-backup state (NodeNetworkState) - field
#      names for the per-member status block are NOT fully stable
#      across NMState versions (researched: observed as something like
#      a "bond-subordinate"/"link-aggregation" status block on the
#      MEMBER interface's own entry, not nested under the bond) - this
#      section prints the raw member interface status for manual
#      reading rather than parsing an unconfirmed field name
#   4. Two-way reconciliation: trunk VLANs with no NAD, NAD VLANs not
#      on the trunk
#
# Mechanism B verifies:
#   1. Duplicate VLAN IDs within the same physicalNetworkName (a VLAN
#      ID reused across DIFFERENT physicalNetworkName values is normal
#      and expected, not a conflict - confirmed live with phys-bond1/
#      phys-bond2 both using overlapping low VLAN ID ranges elsewhere)
#   2. Every CUDN's status.conditions has NetworkCreated=True (i.e.
#      the NAD was actually generated, not just the CUDN spec existing)
#   3. Every CUDN's namespaceSelector actually matches at least one
#      namespace (a selector matching nothing is a silent dead config -
#      the CUDN "succeeds" but produces a NAD nowhere anyone can use)
set -euo pipefail

BOND_NAME="${BOND_NAME:-}"
WORKDIR="${TMPDIR:-/tmp}"

HAS_CUDN=$(oc get clusteruserdefinednetworks.k8s.ovn.org --no-headers 2>/dev/null | wc -l)
if [ "$HAS_CUDN" -gt 0 ]; then
  echo "### Detected mechanism B: ${HAS_CUDN} ClusterUserDefinedNetwork(s) found - running CUDN/UDN reconciliation ###"
  echo

  echo "### 1. Duplicate VLAN IDs WITHIN the same physicalNetworkName (real conflict) ###"
  echo "# (same VLAN ID on DIFFERENT physicalNetworkName values is normal, not flagged)"
  oc get network-attachment-definitions -A -o json \
    | jq -r '
        [.items[] | (.spec.config | fromjson?) as $c
          | select($c.vlanID != null and $c.physicalNetworkName != null)
          | {ns: .metadata.namespace, name: .metadata.name, phys: $c.physicalNetworkName, vlan: $c.vlanID}]
        | group_by(.phys + "/" + (.vlan | tostring))
        | map(select(length > 1))
        | .[] | "physicalNetworkName \(.[0].phys), VLAN \(.[0].vlan) used by: " + ([.[] | "\(.ns)/\(.name)"] | join(", "))'
  echo "(empty above = no VLAN ID conflicts within any single physicalNetworkName)"

  echo
  echo "### 2. CUDNs where NetworkCreated status condition is NOT True (NAD was not actually generated) ###"
  oc get clusteruserdefinednetworks.k8s.ovn.org -o json \
    | jq -r '
        .items[]
        | select(((.status.conditions // []) | map(select(.type == "NetworkCreated")) | first | .status // "Unknown") != "True")
        | "\(.metadata.name): NetworkCreated=" + (((.status.conditions // []) | map(select(.type == "NetworkCreated")) | first | .status) // "MISSING") + " (" + (((.status.conditions // []) | map(select(.type == "NetworkCreated")) | first | .message) // "no condition found") + ")"'
  echo "(empty above = every CUDN successfully created its NAD)"

  echo
  echo "### 3. CUDNs whose namespaceSelector matches ZERO namespaces (silent dead config) ###"
  ALL_NS_LABELS=$(oc get namespaces -o json | jq -c '[.items[] | .metadata.labels // {}]')
  JQ_SELECTOR_MATCHES='
    def selector_matches($cudn; $nslabels):
      ($cudn.spec.namespaceSelector.matchExpressions // []) as $exprs
      | ($cudn.spec.namespaceSelector.matchLabels // {}) as $matchlabels
      | [$nslabels[] | . as $labels
          | select(
              ($exprs | all(. as $e
                  | ($labels[$e.key] // null) as $v
                  | if $e.operator == "In" then ($v != null and ($e.values | index($v)) != null)
                    elif $e.operator == "NotIn" then ($v == null or ($e.values | index($v)) == null)
                    elif $e.operator == "Exists" then ($v != null)
                    elif $e.operator == "DoesNotExist" then ($v == null)
                    else true end))
              and ($matchlabels | to_entries | all(. as $kv | $labels[$kv.key] == $kv.value))
            )
        ] | length;
  '
  oc get clusteruserdefinednetworks.k8s.ovn.org -o json \
    | jq -r --argjson nslabels "$ALL_NS_LABELS" "
        ${JQ_SELECTOR_MATCHES}
        .items[]
        | . as \$cudn
        | select(selector_matches(\$cudn; \$nslabels) == 0)
        | \"\(.metadata.name): namespaceSelector matches 0 namespaces\""
  echo "(empty above = every CUDN's namespaceSelector matches at least one namespace)"

  echo
  echo "### 4. UDN <-> NAD reconciliation table (per CUDN: OK = NAD exists and owned by this CUDN, ORPHAN = missing/mismatched) ###"
  EXISTING_NADS=$(oc get network-attachment-definitions -A -o json \
    | jq -c '[.items[] | {ns: .metadata.namespace, name: .metadata.name, owner: ((.metadata.ownerReferences // [])[0].name // "")}]')
  oc get clusteruserdefinednetworks.k8s.ovn.org -o json \
    | jq -r --argjson nads "$EXISTING_NADS" '
        ["CUDN","NAD-NAMESPACE","STATUS"],
        (.items[] | . as $cudn
          | ($nads | map(select(.owner == $cudn.metadata.name))) as $owned
          | if ($owned | length) > 0
            then $owned[] | [$cudn.metadata.name, .ns, "OK (NAD=\(.ns)/\(.name))"]
            else [$cudn.metadata.name, "-", "ORPHAN (no NAD owned by this CUDN found)"]
            end)
        | @tsv' \
    | column -t -s $'\t'
  echo "### Reverse check: NADs that LOOK UDN-managed (k8s.ovn.org/user-defined-network label) but have no owning CUDN ###"
  oc get network-attachment-definitions -A -o json \
    | jq -r '
        .items[]
        | select((.metadata.labels["k8s.ovn.org/user-defined-network"] // null) != null)
        | select(((.metadata.ownerReferences // [])[0].kind // "") != "ClusterUserDefinedNetwork")
        | "\(.metadata.namespace)/\(.metadata.name): ORPHAN (UDN label present, no owning ClusterUserDefinedNetwork)"'
  echo "(empty above = every UDN-labeled NAD has a live owning CUDN)"

  echo
  echo "### Summary: physicalNetworkName -> VLAN IDs in use ###"
  oc get network-attachment-definitions -A -o json \
    | jq -r '
        [.items[] | (.spec.config | fromjson?) as $c | select($c.vlanID != null) | {phys: $c.physicalNetworkName, vlan: $c.vlanID}]
        | group_by(.phys)
        | map({phys: .[0].phys, vlans: (map(.vlan) | unique | sort)})
        | .[] | "\(.phys): \(.vlans | length) VLAN(s) - \(.vlans | join(","))"'

  exit 0
fi

echo "### No ClusterUserDefinedNetworks found - falling back to mechanism A (NMState/NNCP trunk reconciliation) ###"
if [ -z "$BOND_NAME" ]; then
  echo "BOND_NAME is not set. Set BOND_NAME to the bond interface name, e.g.:" >&2
  echo "  BOND_NAME=bond0 ./22_check_vlan_trunk_reconciliation.sh" >&2
  exit 1
fi

echo "### 1. NAD VLANs: duplicate VLAN IDs across NetworkAttachmentDefinitions ###"
oc get network-attachment-definitions -A -o json \
  | jq -r '
      [.items[] | {ns: .metadata.namespace, name: .metadata.name, vlan: ((.spec.config | fromjson? | .vlan) // empty)}]
      | group_by(.vlan)
      | map(select(length > 1 and .[0].vlan != null))
      | .[] | "VLAN \(.[0].vlan) used by: " + ([.[] | "\(.ns)/\(.name)"] | join(", "))'
echo "(empty above = no duplicate VLAN IDs across NADs)"

echo
echo "### 2. NNCP-managed VLAN sub-interfaces on ${BOND_NAME} (the actual trunk, built by enumeration) ###"
oc get nncp -o json \
  | jq -r --arg bond "$BOND_NAME" '
      [.items[] | (.spec.desiredState.interfaces // [])[]
        | select(.type == "vlan" and .vlan["base-iface"] == $bond)
        | .vlan.id]
      | unique | sort | .[]' \
  | sort -n > "${WORKDIR}/trunk_vlans.$$"

echo "Trunked VLANs on ${BOND_NAME} ($(wc -l < "${WORKDIR}/trunk_vlans.$$") total):"
cat "${WORKDIR}/trunk_vlans.$$"

echo
echo "### NAD-referenced VLANs ###"
oc get network-attachment-definitions -A -o json \
  | jq -r '[.items[] | (.spec.config | fromjson? | .vlan) // empty] | unique | sort | .[]' \
  | sort -n > "${WORKDIR}/nad_vlans.$$"
echo "NAD-referenced VLANs ($(wc -l < "${WORKDIR}/nad_vlans.$$") total):"
cat "${WORKDIR}/nad_vlans.$$"

echo
echo "### 4. Two-way reconciliation ###"
echo "--- Trunked on ${BOND_NAME} but NO matching NAD (wasted/unused VLAN) ---"
comm -23 "${WORKDIR}/trunk_vlans.$$" "${WORKDIR}/nad_vlans.$$"
echo "--- Referenced by a NAD but NOT trunked on ${BOND_NAME} (will not actually pass traffic) ---"
comm -13 "${WORKDIR}/trunk_vlans.$$" "${WORKDIR}/nad_vlans.$$"
rm -f "${WORKDIR}/trunk_vlans.$$" "${WORKDIR}/nad_vlans.$$"

echo
echo "### 3. Bond member link state (NodeNetworkState) - raw output, field names vary by NMState version ###"
echo "# Repeat per node; the member interfaces are whatever was configured as link-aggregation.port on ${BOND_NAME}:"
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- ${NODE}: ${BOND_NAME} status ---"
  oc get nns "$NODE" -o json 2>/dev/null \
    | jq --arg bond "$BOND_NAME" '.status.currentState.interfaces[] | select(.name == $bond) | {name, state, "link-aggregation"}' \
    || echo "(NodeNetworkState not found for ${NODE} - NMState may not be installed)"
done
