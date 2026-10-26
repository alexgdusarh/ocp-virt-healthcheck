#!/usr/bin/env bash
# Check: ClusterVersion status
#
# Verifies:
#   - current cluster version (desired/history)
#   - overall Progressing/Available/Degraded conditions
#   - whether any TechPreviewNoUpgrade (or other FeatureGate) is enabled,
#     since that blocks future upgrades and is relevant before trusting
#     OCP-Virt behavior as fully supported/GA
set -euo pipefail

echo "### ClusterVersion: current version and update channel ###"
oc get clusterversion version \
  -o jsonpath='{.status.desired.version}{"\n"}'

oc get clusterversion version \
  -o jsonpath='Channel: {.spec.channel}{"\n"}'

echo
echo "### ClusterVersion: overall conditions (Available / Progressing / Degraded / Failing) ###"
oc get clusterversion version -o json \
  | jq -r '.status.conditions[] | [.type, .status, .message] | @tsv'

echo
echo "### FeatureGate: TechPreviewNoUpgrade / featureSet ###"
oc get featuregate cluster -o json \
  | jq -r '
      if (.spec.featureSet // "") == "" then
        "featureSet: (default - no TechPreview enabled)"
      else
        "featureSet: " + .spec.featureSet
      end'

echo
echo "### ClusterVersion: full status (for reference, raw JSON) ###"
oc get clusterversion version -o json \
  | jq '.status | {desired, conditions, history: .history[0:5]}'
