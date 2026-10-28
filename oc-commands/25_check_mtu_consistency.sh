#!/usr/bin/env bash
# Check: MTU consistency across NNCP (physical NIC/bond/bridge),
# NNS (actual live state), and the VM/storage networks riding on top
#
# Verified against real must-gather data from a cluster with
# bond0 (default cluster, NMState-unmanaged - installer-configured),
# bond1 (VM network, OVS bridge br-bond1), bond2 (storage network,
# OVS bridge br-bond2, csi.trident.netapp.io StorageClasses):
#
#  - NNCP does not set `mtu` on any interface on this cluster - every
#    bond/bridge/VLAN defaults to 1500. NMState's `mtu` field is
#    OPTIONAL per-interface; omitting it does not mean "inherit from
#    parent", it means "use the kernel default" (1500), which is why
#    this script compares NNCP-declared (where present) AND NNS-
#    actual (always present) rather than NNCP alone - an omitted NNCP
#    mtu is not evidence of anything, only NNS shows ground truth.
#  - The VLAN-to-bond mapping for UDN/CUDN localnet NADs is NOT
#    discoverable from the NAD's `physicalNetworkName` by naming
#    convention alone ("phys-bond1" does not formally mean "bond1") -
#    the authoritative live mapping is
#    status.currentState.ovn.bridge-mappings on the NodeNetworkState
#    (localnet name -> bridge name), cross-referenced with the NNCP's
#    ovs-bridge.bridge.port[].name (bridge name -> underlying bond).
#  - OVS bridge interfaces (type: ovs-bridge) report mtu: null/None at
#    the bridge-type entry itself in NNS; the real MTU lives on the
#    nested ovs-interface entry of the same name - comparing the
#    bridge-type entry's mtu would always show null, a false gap.
#  - OVN-K's internal overlay interfaces (br-int, patch-*) legitimately
#    run a different MTU (seen: br-int at 1400, geneve overlay
#    encapsulation overhead) and are reported with state: ignore -
#    these are correctly excluded, not flagged.
#  - NetApp's documented best practice for Trident-backed storage LANs
#    is end-to-end jumbo frames (MTU 9000); this is NOT enforced as a
#    FAIL (1500 works, just underperforms) - reported as an
#    informational note only, scoped to whichever bond actually
#    backs Trident-provisioned storage traffic.
set -euo pipefail

echo "### 1. NNCP-declared MTU per node (bond/bridge/vlan interfaces; blank = not set, defaults to kernel 1500) ###"
oc get nncp -o json \
  | jq -r '
      ["NODE-SELECTOR/NNCP","INTERFACE","TYPE","DECLARED-MTU"],
      (.items[] | . as $p | ($p.spec.nodeSelector["kubernetes.io/hostname"] // $p.metadata.name) as $node
        | ($p.spec.desiredState.interfaces // [])[]
        | select(.type == "bond" or .type == "ovs-bridge" or .type == "vlan" or .type == "linux-bridge")
        | [$node, .name, .type, (.mtu | tostring)])
      | @tsv' \
  | column -t

echo
echo "### 2. NNS-actual MTU per node (ground truth - what the kernel is really running) ###"
echo "# OVS bridge TYPE entries legitimately show no mtu (null) - the real value is on"
echo "# the matching ovs-interface entry of the same name, shown separately below."
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- ${NODE} ---"
  oc get nns "$NODE" -o json 2>/dev/null \
    | jq -r '
        ["INTERFACE","TYPE","ACTUAL-MTU","STATE"],
        (.status.currentState.interfaces[]
          | select(.type == "bond" or .type == "vlan" or .type == "linux-bridge"
                    or (.type == "ovs-interface" and (.state // "") != "ignore"))
          | [.name, .type, (.mtu | tostring), (.state // "-")])
        | @tsv' \
    | column -t \
    || echo "(NodeNetworkState not found for ${NODE} - NMState may not be installed)"
done

echo
echo "### 3. Cross-node MTU consistency per bond (same bond name should report the same MTU on every node) ###"
oc get nns -o json \
  | jq -r '
      [.items[] | . as $nns | ($nns.metadata.name) as $node
        | ($nns.status.currentState.interfaces[] | select(.type == "bond")) as $iface
        | {node: $node, bond: $iface.name, mtu: $iface.mtu}]
      | group_by(.bond)
      | .[] | {bond: .[0].bond, mtus: (map(.mtu) | unique)} as $g
      | if ($g.mtus | length) > 1
        then "MISMATCH: bond \($g.bond) reports different MTUs across nodes: " + ([.[] | "\(.node)=\(.mtu)"] | join(", "))
        else "OK: bond \($g.bond) = \($g.mtus[0]) on all nodes"
        end' \
  2>/dev/null || echo "(could not evaluate - check 'oc get nns' output above)"

echo
echo "### 4. Parent/child MTU ceiling violations (a VLAN/bridge MUST NOT exceed its parent bond's actual MTU) ###"
for NODE in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  oc get nns "$NODE" -o json 2>/dev/null | jq -r --arg node "$NODE" '
      (.status.currentState.interfaces) as $ifaces
      | ($ifaces | map(select(.type == "bond")) | map({(.name): .mtu}) | add // {}) as $bond_mtus
      | $ifaces[]
      | select(.type == "vlan" and .vlan["base-iface"] != null)
      | . as $v
      | ($bond_mtus[$v.vlan["base-iface"]]) as $parent_mtu
      | select($parent_mtu != null and $v.mtu != null and ($v.mtu | tonumber) > ($parent_mtu | tonumber))
      | "\($node): VLAN \($v.name) mtu=\($v.mtu) EXCEEDS parent \($v.vlan["base-iface"]) mtu=\($parent_mtu)"'
done
echo "(empty above = no VLAN exceeds its parent bond's MTU on any node)"

echo
echo "### 5. UDN/CUDN NAD mtu vs the actual bond it rides on (via ovn.bridge-mappings + NNCP bridge port) ###"
HAS_CUDN=$(oc get clusteruserdefinednetworks.k8s.ovn.org --no-headers 2>/dev/null | wc -l)
if [ "$HAS_CUDN" -gt 0 ]; then
  NODE1=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
  BRIDGE_MAPPINGS=$(oc get nns "$NODE1" -o json | jq -c '.status.currentState.ovn["bridge-mappings"] // []')
  BOND_MTUS=$(oc get nns "$NODE1" -o json | jq -c '[.status.currentState.interfaces[] | select(.type == "bond") | {bond: .name, mtu: .mtu}]')
  BRIDGE_PORTS=$(oc get nncp -o json | jq -c '
      [.items[].spec.desiredState.interfaces[]? | select(.type == "ovs-bridge") | {bridge: .name, port: (.bridge.port[0].name // null)}] | unique')

  oc get network-attachment-definitions -A -o json \
    | jq -r --argjson maps "$BRIDGE_MAPPINGS" --argjson bonds "$BOND_MTUS" --argjson ports "$BRIDGE_PORTS" --arg node1 "$NODE1" '
        .items[]
        | (.spec.config | fromjson?) as $c
        | select($c.physicalNetworkName != null and $c.mtu != null)
        | ($maps | map(select(.localnet == $c.physicalNetworkName)) | first | .bridge) as $bridge
        | ($ports | map(select(.bridge == $bridge)) | first | .port) as $bond
        | ($bonds | map(select(.bond == $bond)) | first | .mtu) as $bond_mtu
        | if $bond == null then
            "\(.metadata.namespace)/\(.metadata.name): physicalNetworkName \($c.physicalNetworkName) has no bridge-mapping on \($node1) - cannot resolve underlying bond"
          elif $bond_mtu == null then
            "\(.metadata.namespace)/\(.metadata.name): resolved to bond \($bond) but its MTU could not be read"
          elif ($c.mtu | tonumber) > ($bond_mtu | tonumber) then
            "\(.metadata.namespace)/\(.metadata.name): NAD mtu=\($c.mtu) EXCEEDS underlying bond \($bond) mtu=\($bond_mtu) (physicalNetworkName=\($c.physicalNetworkName))"
          else
            "\(.metadata.namespace)/\(.metadata.name): OK (mtu=\($c.mtu) <= bond \($bond) mtu=\($bond_mtu))"
          end'
else
  echo "(no ClusterUserDefinedNetworks found - skipping; see check 22 for the NMState/NNCP-manual-NAD equivalent)"
fi

echo
echo "### 6. INFORMATIONAL: storage bond MTU vs NetApp's documented jumbo-frame best practice ###"
echo "# NetApp's documented best practice for Trident-backed storage LANs is end-to-end"
echo "# jumbo frames (MTU 9000). 1500 still works (not a failure), it just means storage"
echo "# traffic is not benefiting from reduced per-frame overhead on bulk I/O."
TRIDENT_SC=$(oc get storageclass -o json | jq -r '[.items[] | select(.provisioner == "csi.trident.netapp.io") | .metadata.name] | length')
if [ "$TRIDENT_SC" -gt 0 ]; then
  echo "# ${TRIDENT_SC} Trident StorageClass(es) found on this cluster."
  echo "# Review which bond actually carries storage traffic (commonly the one named for"
  echo "# storage, e.g. bond2 above) and confirm with the storage team whether jumbo frames"
  echo "# were intended end-to-end (cluster bond AND the upstream switch/NetApp SVM side -"
  echo "# switch-side MTU is NOT visible from inside the cluster and must be confirmed"
  echo "# separately)."
else
  echo "# No csi.trident.netapp.io StorageClass found - this note does not apply."
fi
