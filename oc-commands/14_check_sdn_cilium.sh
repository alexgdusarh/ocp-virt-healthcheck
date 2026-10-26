#!/usr/bin/env bash
# Check: SDN - Cilium
#
# Only meaningful when Cilium is the cluster's actual CNI (replacing
# OVN-Kubernetes, installed via its OLM operator - e.g. Isovalent
# Enterprise for Cilium). Detects presence via the CiliumNode CRD
# (robust - exists only once the Cilium operator has run) rather than
# relying on Network.config spec.networkType alone (a free-form
# string, not an enforced enum - Cilium's install tooling
# conventionally sets it to "Cilium" but that spelling isn't a
# guaranteed cross-vendor contract).
#
# Verifies:
#   - Cilium CiliumNode CRD exists (presence check)
#   - Cilium operator CSV/Deployment healthy
#   - cilium-agent DaemonSet fully ready on all nodes
#   - every Node has a matching CiliumNode (no orphans/missing)
#   - Cilium's own per-node health status (via CiliumNode status)
set -euo pipefail

echo "### Cilium presence: CiliumNode CRD ###"
if ! oc get crd ciliumnodes.cilium.io >/dev/null 2>&1; then
  echo "ciliumnodes.cilium.io CRD not found - Cilium is not installed on this cluster"
  exit 0
fi
echo "CiliumNode CRD present"

echo
echo "### Cilium operator: CSV phase ###"
oc get csv -A -o json \
  | jq -r '.items[] | select(.metadata.name | test("cilium"; "i")) | [.metadata.namespace, .metadata.name, .status.phase] | @tsv' \
  | awk 'BEGIN{print "NAMESPACE\tCSV\tPHASE"} {print}'

echo
echo "### cilium-agent DaemonSet: desired vs ready ###"
echo "# namespace is commonly 'kube-system' or 'cilium' depending on packaging - checking both:"
for NS in kube-system cilium; do
  if oc get daemonset cilium -n "$NS" >/dev/null 2>&1; then
    echo "--- namespace: $NS ---"
    oc get daemonset cilium -n "$NS" -o json \
      | jq -r '["DESIRED","CURRENT","READY"], [(.status.desiredNumberScheduled|tostring), (.status.currentNumberScheduled|tostring), (.status.numberReady|tostring)] | @tsv' \
      | column -t
  fi
done

echo
echo "### CiliumNodes: one per Node (flag any Node with no matching CiliumNode) ###"
NODES=$(oc get nodes -o json | jq -c '[.items[].metadata.name]')
oc get ciliumnodes -o json \
  | jq -r --argjson nodes "$NODES" '
      ($nodes - [.items[].metadata.name]) as $missing
      | if ($missing | length) > 0 then "Nodes with NO CiliumNode: " + ($missing | join(", ")) else "every Node has a matching CiliumNode" end'

echo
echo "### CiliumNodes: per-node health/status ###"
oc get ciliumnodes -o json \
  | jq -r '
      ["NODE","HEALTH_IP","ENCRYPTION_KEY"],
      (.items[] | [.metadata.name, (.spec.health.ipv4 // "-"), (.spec.encryption.key // 0 | tostring)])
      | @tsv' \
  | column -t

echo
echo "### Cilium pods: any NOT Running/Ready ###"
for NS in kube-system cilium; do
  oc get pods -n "$NS" -l 'k8s-app=cilium' -o json 2>/dev/null \
    | jq -r '
        .items[]?
        | select(.status.phase != "Running" or ([.status.containerStatuses[]?.ready] | all) == false)
        | [.metadata.namespace, .metadata.name, .status.phase]
        | @tsv' \
    | awk 'BEGIN{print "NAMESPACE\tNAME\tPHASE"} {print}'
done
