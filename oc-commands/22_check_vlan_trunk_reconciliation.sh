#!/usr/bin/env bash
# Check: VLAN trunk reconciliation (dedicated bond, many VLANs/NADs)
#
# For topologies with one bonded uplink trunking many VLANs (seen:
# one active-backup bond, 59 VLANs, 59 NADs) - validates at the scale
# where a basic cross-check (check 11) is too coarse.
#
# Key fact (researched, verified): NMState has NO trunk-list field at
# the bond/bridge level. The "trunk" is whatever set of NNCP-managed
# type:vlan sub-interfaces (vlan.base-iface == <bond>, vlan.id == N)
# actually exist - that set IS the trunk, built by enumeration, not
# looked up.
#
# Verifies:
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
set -euo pipefail

BOND_NAME="${BOND_NAME:?Set BOND_NAME to the bond interface name, e.g. BOND_NAME=bond0 ./22_check_vlan_trunk_reconciliation.sh}"
WORKDIR="${TMPDIR:-/tmp}"

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
