#!/usr/bin/env bash
# Check: ClusterOperators status
#
# Verifies every ClusterOperator reports Available=True, Progressing=False,
# Degraded=False. Flags any operator that isn't in that steady state.
set -euo pipefail

echo "### ClusterOperators: quick table ###"
oc get co

echo
echo "### ClusterOperators: operators NOT in healthy steady state ###"
oc get co -o json \
  | jq -r '
      .items[]
      | {
          name: .metadata.name,
          available: (.status.conditions[]? | select(.type=="Available") | .status),
          progressing: (.status.conditions[]? | select(.type=="Progressing") | .status),
          degraded: (.status.conditions[]? | select(.type=="Degraded") | .status)
        }
      | select(.available != "True" or .progressing != "False" or .degraded != "False")
      | [.name, .available, .progressing, .degraded] | @tsv' \
  | awk 'BEGIN { print "NAME\tAVAILABLE\tPROGRESSING\tDEGRADED" } { print }'

echo
echo "### If any listed above, get the Degraded/Progressing message ###"
echo "oc get co <name> -o jsonpath='{.status.conditions}' | jq ."
