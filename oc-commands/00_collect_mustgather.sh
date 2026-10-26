#!/usr/bin/env bash
# Collect: must-gather (general + OpenShift Virtualization)
#
# Run this FIRST, before any check below, so the full cluster state is
# captured for later/offline analysis alongside the live checks.
#
# Image tags must match the installed OCP / CNV minor version - check
# first if unsure:
#   oc get clusterversion version -o jsonpath='{.status.desired.version}{"\n"}'
#   oc get csv -n openshift-cnv -o jsonpath='{.items[0].spec.version}{"\n"}'
#
# Supported at the time of writing: OCP 4.20 and 4.22 (adjust OCP_VERSION
# below to match the actual cluster - do not assume).
set -euo pipefail

OCP_VERSION="${OCP_VERSION:-4.20}"   # or 4.22 - match the cluster's actual version
OUTDIR="${MUSTGATHER_OUTDIR:-./mustgather-$(date +%Y%m%dT%H%M%SZ)}"

mkdir -p "$OUTDIR"

echo "### 1. General must-gather (pinned to OCP v${OCP_VERSION}) ###"
oc adm must-gather \
  --image="registry.redhat.io/openshift4/ose-must-gather:v${OCP_VERSION}" \
  --dest-dir="${OUTDIR}/general"

echo
echo "### 2. OpenShift Virtualization must-gather (pinned to CNV v${OCP_VERSION}) ###"
oc adm must-gather \
  --image="registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v${OCP_VERSION}" \
  --dest-dir="${OUTDIR}/virtualization" \
  -- /usr/bin/gather

echo
echo "### Done. Output under: ${OUTDIR} ###"
echo "# To target a specific VM incident instead of a full gather (CNV must-gather only, v4.22+):"
echo "oc adm must-gather \\"
echo "  --image=registry.redhat.io/container-native-virtualization/cnv-must-gather-rhel9:v${OCP_VERSION} \\"
echo "  --dest-dir=\"${OUTDIR}/virtualization-incident\" \\"
echo "  -- NS=<namespace> VM=<vm-name> /usr/bin/gather --vm-incident --incident-time=<RFC3339-timestamp>"
