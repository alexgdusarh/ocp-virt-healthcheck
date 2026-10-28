#!/usr/bin/env bash
# Check: CNV internal certificates (TLS handshake / trust diagnostics)
#
# KubeVirt runs its own self-signed CA (not cert-manager) for internal
# mTLS between virt-api/virt-controller/virt-handler. Server certs
# default to a 24h lifetime (CA: 168h), rotating at 80% of lifetime -
# a stuck rotation becomes a real outage within ~24h, faster than
# typical "cert expired" bugs on longer-lived components.
#
# Verifies:
#   - expiry/validity window on every kubevirt-*-certs Secret + the
#     CA itself
#   - virt-handler DaemonSet actually mounts kubevirt-virt-handler-certs
#     at the expected path (a documented real failure signature: "failed
#     to load the certificate /etc/virt-handler/clientcertificates/..."
#     is a MOUNT defect, not a trust-chain problem - distinct root cause)
#   - virt-handler pod logs for TLS/x509 error strings (handshake vs.
#     mount-failure signatures, so you know which class you're facing)
#   - cluster-wide Proxy noProxy coverage (HEURISTIC ONLY - see note
#     below, this is not a documented CNV failure mode, just a
#     mechanically plausible precondition worth ruling in/out)
#
# NOTE on "failed to load the certificate ... private key does not
# match public key": verified against real client must-gather data,
# this fires on a steady ~12h cadence (clustering around :27/:28 past
# the hour) across virt-handler AND virt-controller, for multiple
# independent Secrets (server/client/exportca certs) - a torn read of
# the projected Secret volume during the cert watcher's periodic
# reload, not a persisted bad keypair.
#
# CORRECTED (real-world RCA from the client engagement, confirmed
# directly against the live cluster): "is this error still the LAST
# matching line in the log tail" is NOT a reliable self-clear signal
# and produces false positives - virt-handler does not log a positive
# "cert reloaded OK" confirmation on success, so a benign occurrence
# that recovered within the same second looks IDENTICAL in the log
# tail to one that never recovered (both just show the error as the
# last relevant line - there is no distinguishing "it worked" entry
# to find afterward). The client's RCA used the actual correct
# signal instead: pod restart count and Running/Ready state. Zero
# restarts correlated with the error's timestamps, and the pod stayed
# Running/Ready throughout, meaning TLS availability was never
# actually interrupted. This check now uses THAT signal - restart
# count and current Running/Ready state - not log-tail position.
set -euo pipefail

NS="${CNV_NAMESPACE:-openshift-cnv}"

echo "### Certificate validity: CA + all kubevirt-*-certs Secrets ###"
for SECRET in kubevirt-ca kubevirt-virt-handler-certs kubevirt-virt-handler-server-certs \
              kubevirt-virt-handler-migration-client-certs kubevirt-virt-api-certs kubevirt-controller-certs; do
  echo "--- ${SECRET} ---"
  CRT=$(oc get secret "$SECRET" -n "$NS" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  if [ -z "$CRT" ]; then
    echo "Secret not found (may not exist in this KubeVirt version, or CNV not installed)"
    continue
  fi
  echo "$CRT" | base64 -d | openssl x509 -noout -dates -subject -issuer 2>/dev/null \
    || echo "Could not decode certificate"
done

echo
echo "### virt-handler DaemonSet: does it mount kubevirt-virt-handler-certs? ###"
oc get daemonset virt-handler -n "$NS" -o json \
  | jq -r '
      .spec.template.spec.volumes[]?
      | select(.secret.secretName == "kubevirt-virt-handler-certs")
      | "Volume \(.name) -> Secret \(.secret.secretName)"'
echo "(empty above = kubevirt-virt-handler-certs is NOT mounted - matches the documented"
echo " \"failed to load the certificate /etc/virt-handler/clientcertificates/...\" failure signature)"

echo
echo "### virt-handler pods: grep logs for TLS/x509 error signatures, correlate with restarts ###"
for POD in $(oc get pods -n "$NS" -l kubevirt.io=virt-handler -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- ${POD} ---"
  LOG=$(oc logs -n "$NS" "$POD" --tail=500 2>/dev/null)
  echo "$LOG" | grep -iE "x509:|tls: bad certificate|tls: handshake failure|certificate signed by unknown authority|certificate has expired|remote error: tls" \
    && echo "^^^ sustained TLS/x509 trust error - investigate" \
    || echo "(no sustained TLS/x509 trust error strings found in last 500 lines)"

  PHASE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  READY=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="virt-handler")].ready}' 2>/dev/null)
  RESTARTS=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.status.containerStatuses[?(@.name=="virt-handler")].restartCount}' 2>/dev/null)
  MISMATCH_COUNT=$(echo "$LOG" | grep -c "does not match public key" || true)

  if [ "${MISMATCH_COUNT:-0}" -gt 0 ]; then
    echo "NOTE: ${MISMATCH_COUNT} certificate/key mismatch occurrence(s) in the last 500 log lines."
    echo "  pod phase=${PHASE:-unknown} ready=${READY:-unknown} restartCount=${RESTARTS:-unknown}"
    if [ "${PHASE:-}" = "Running" ] && [ "${READY:-}" = "true" ] && [ "${RESTARTS:-0}" -eq 0 ]; then
      echo "  -> benign: pod is Running/Ready with zero restarts - consistent with the documented"
      echo "     ~12h reload race (verified RCA: the next cert read succeeds within the same second,"
      echo "     no TLS availability gap since rotation completes well before the old cert expires)."
    else
      echo "  -> INVESTIGATE: pod is NOT cleanly Running/Ready with zero restarts - correlate the"
      echo "     mismatch timestamps above against 'oc get pod ${POD} -n ${NS} -o yaml' restart"
      echo "     history (lastState.terminated.finishedAt) before concluding this is benign."
    fi
  fi
done

echo
echo "### HEURISTIC (not a documented CNV failure mode - mechanistic inference only): ###"
echo "### cluster-wide Proxy noProxy coverage for in-cluster traffic ###"
oc get proxy cluster -o json \
  | jq -r '
      "httpProxy: \(.spec.httpProxy // "none")",
      "httpsProxy: \(.spec.httpsProxy // "none")",
      "status.noProxy: \(.status.noProxy // "none")"'
echo
echo "# If httpProxy/httpsProxy is set, confirm status.noProxy includes cluster-local"
echo "# domains (.cluster.local, .svc, pod/service network CIDRs) - if virt-handler's"
echo "# calls to virt-api/virt-controller (*.pod.cluster.local / *.svc) are NOT covered,"
echo "# that traffic could be routed through the proxy, whose re-signed cert (if it does"
echo "# TLS inspection) is NOT in KubeVirt's closed kubevirt-ca trust bundle - this would"
echo "# surface as: x509: certificate signed by unknown authority"
