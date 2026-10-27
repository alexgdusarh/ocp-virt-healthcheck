#!/usr/bin/env bash
# Check: RBAC/SCC sanity for OpenShift Virtualization service accounts
#
# A surprisingly common "VMs silently can't start" root cause: a
# well-meaning but overly-restrictive cluster security policy strips
# an SCC binding or RoleBinding that CNV's service accounts need,
# tightening the openshift-cnv namespace's Pod Security Admission
# enforce level underneath it (confirmed mechanism: OCP's PSA
# label-sync controller computes the enforce label from the most-
# privileged SCC each namespace's service accounts are bound to - it
# is NOT a manually-set label you'd find by searching for an edit).
#
# This check reads LIVE state rather than asserting fixed expected
# values, since SCC field contents (e.g. kubevirt-controller's
# allowedCapabilities) are version-dependent and not worth hard-coding.
set -euo pipefail

echo "### kubevirt-handler SCC: users bound ###"
oc get scc kubevirt-handler -o json 2>/dev/null \
  | jq -r '.users[]?' \
  || echo "kubevirt-handler SCC not found"

echo
echo "### kubevirt-controller SCC: users bound ###"
oc get scc kubevirt-controller -o json 2>/dev/null \
  | jq -r '.users[]?' \
  || echo "kubevirt-controller SCC not found"

echo
echo "### ClusterRoleBindings referencing CNV service accounts (openshift-cnv) ###"
oc get clusterrolebindings -o json \
  | jq -r '
      ["CLUSTERROLEBINDING","ROLE","SUBJECT"],
      (.items[]
        | select(.subjects[]? | select(.namespace == "openshift-cnv" and (.name | test("hco-operator|cdi-operator|virt-operator|virt-api|virt-controller|virt-handler|kubevirt-"))))
        | [.metadata.name, .roleRef.name, ([.subjects[].name] | join(","))])
      | @tsv' \
  | column -t

echo
echo "### openshift-cnv namespace: current Pod Security Admission labels (live, not asserted) ###"
oc get namespace openshift-cnv -o json \
  | jq -r '.metadata.labels | to_entries[] | select(.key | startswith("pod-security.kubernetes.io/")) | "\(.key)=\(.value)"'

echo
echo "### Cross-check: can the virt-handler/virt-launcher SAs actually use their SCC? ###"
oc adm policy who-can use scc kubevirt-handler 2>&1 | grep -v "^$" || true
echo "---"
oc adm policy who-can use scc kubevirt-controller 2>&1 | grep -v "^$" || true

echo
echo "### virt-launcher pods: any Pending/stuck with security-context admission errors (describe the newest one if present) ###"
STUCK_POD=$(oc get pods -A -l kubevirt.io=virt-launcher --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
STUCK_NS=$(oc get pods -A -l kubevirt.io=virt-launcher --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
if [ -n "$STUCK_POD" ]; then
  echo "Pending virt-launcher pod found: ${STUCK_NS}/${STUCK_POD} - describe output:"
  oc describe pod -n "$STUCK_NS" "$STUCK_POD" | grep -iA3 "securitycontext\|forbidden\|violat"
else
  echo "No Pending virt-launcher pods found"
fi
