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
# reload, not a persisted bad keypair. It self-clears on the next
# reload tick with zero correlated TLS handshake failures observed.
# Only treat it as a real problem if it is STILL the most recent
# matching line in the log tail (i.e. never self-cleared).
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
echo "### virt-handler pods: grep logs for TLS/x509 error signatures ###"
for POD in $(oc get pods -n "$NS" -l kubevirt.io=virt-handler -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- ${POD} ---"
  LOG=$(oc logs -n "$NS" "$POD" --tail=500 2>/dev/null)
  echo "$LOG" | grep -iE "x509:|tls: bad certificate|tls: handshake failure|certificate signed by unknown authority|certificate has expired|remote error: tls" \
    && echo "^^^ sustained TLS/x509 trust error - investigate" \
    || echo "(no sustained TLS/x509 trust error strings found in last 500 lines)"

  LAST_CERT_LOAD=$(echo "$LOG" | grep "failed to load the certificate" | tail -1)
  if [ -n "$LAST_CERT_LOAD" ]; then
    if echo "$LAST_CERT_LOAD" | grep -q "does not match public key"; then
      echo "NOTE: most recent cert-load error is still unresolved in the tail:"
      echo "  $LAST_CERT_LOAD"
      echo "  -> if this keeps appearing as the LAST such line on repeat checks, it is NOT"
      echo "     self-clearing and may be a genuinely stuck Secret (not the benign ~12h reload race)."
    else
      echo "(most recent cert-load error, if any, is a 'no such file' mount-defect signature - see check notes)"
      echo "  $LAST_CERT_LOAD"
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
