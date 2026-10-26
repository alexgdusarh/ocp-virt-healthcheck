#!/usr/bin/env bash
# Check: OpenShift Virtualization (CNV) operator + HyperConverged CR
#
# Foundation check: is OCP-Virt actually installed, and does the
# operator consider itself healthy. Verifies:
#   - the CNV Subscription/CSV is installed and in "Succeeded" phase
#   - the HyperConverged CR exists and reports Available/Degraded/
#     Progressing/ReconcileComplete conditions in a healthy state
#   - the CNV operator version (for cross-checking against known
#     issues, same spirit as the ClusterVersion check)
set -euo pipefail

NS="${CNV_NAMESPACE:-openshift-cnv}"

echo "### CNV Subscription/CSV status (namespace: ${NS}) ###"
oc get subscription -n "$NS" -o json \
  | jq -r '.items[] | [.metadata.name, .status.installedCSV, (.status.state // "unknown")] | @tsv' \
  | column -t -N NAME,INSTALLED_CSV,STATE

echo
echo "### ClusterServiceVersion phase (should be Succeeded) ###"
oc get csv -n "$NS" -o json \
  | jq -r '.items[] | select(.metadata.name | test("kubevirt-hyperconverged|virtualization")) | [.metadata.name, .spec.version, .status.phase] | @tsv' \
  | column -t -N NAME,VERSION,PHASE

echo
echo "### HyperConverged CR: conditions ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o json \
  | jq -r '.status.conditions[] | [.type, .status, .reason] | @tsv' \
  | column -t -N TYPE,STATUS,REASON

echo
echo "### HyperConverged CR: operator version reported in status ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o json \
  | jq -r '.status.versions[]? | [.name, .version] | @tsv' \
  | column -t -N COMPONENT,VERSION

echo
echo "### Quick verdict: any condition NOT in the healthy state? ###"
oc get hyperconverged kubevirt-hyperconverged -n "$NS" -o json \
  | jq -r '
      .status.conditions[]
      | select(
          (.type == "Available" and .status != "True")
          or (.type == "Degraded" and .status != "False")
          or (.type == "Progressing" and .status != "False")
          or (.type == "ReconcileComplete" and .status != "True")
        )
      | "\(.type)=\(.status) (\(.reason))"'
