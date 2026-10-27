#!/usr/bin/env bash
# Must-gather analysis driver (uses omc: https://github.com/gmeghnag/omc)
#
# Reusable tooling - not client-specific. Everything this script reads
# must-gather tarballs from and writes findings to lives under mg/,
# which is entirely git-ignored: must-gather tarballs, their extracted
# contents, and generated findings files are confidential and must
# never be committed or pushed.
#
# Install omc first (one-time):
#   curl -sL https://github.com/gmeghnag/omc/releases/latest/download/omc_Linux_x86_64.tar.gz \
#     | tar xz -C ~/.local/bin omc && chmod +x ~/.local/bin/omc
#
# Usage:
#   ./scripts/analyze-mustgather.sh mg/<general-mustgather.tgz> [mg/<virt-mustgather.tgz>]
#
# Output is both printed to the terminal and saved to
# mg/findings-<timestamp>.txt (also git-ignored) for later reference
# without needing to re-run omc.
#
# Implementation notes (learned the hard way - see comments inline):
#   - Tarballs are extracted with plain `tar`, not `omc use <tarball>`
#     directly - omc's own extraction is not idempotent against an
#     already-extracted directory (re-extracts noisily and can leave
#     its "current" must-gather pointed at the wrong one).
#   - `omc mg delete -a` runs before each `omc use` to force a clean,
#     deterministic selection - omc's must-gather tracking/merging
#     across repeated `use` calls on the same paths is not reliable
#     enough to trust implicitly.
#   - Archives collected on macOS commonly carry AppleDouble ._*
#     metadata files (and a com.apple.quarantine xattr) that omc can
#     choke on if one lands on a path it tries to parse as YAML -
#     stripped immediately after each extraction.
set -uo pipefail
# NOTE: deliberately not `set -e` - these are diagnostic probes against
# must-gather data of varying completeness (e.g. etcd_info/ isn't
# always collected); one command's absence/failure shouldn't abort the
# rest of the run.

if ! command -v omc >/dev/null 2>&1; then
  echo "omc not found on PATH. Install from https://github.com/gmeghnag/omc/releases" >&2
  exit 1
fi

GENERAL_TGZ="${1:?Usage: $0 <general-mustgather.tgz> [<virt-mustgather.tgz>]}"
VIRT_TGZ="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MGDIR="${REPO_ROOT}/mg"
EXTRACT_DIR="${MGDIR}/extracted"
FINDINGS="${MGDIR}/findings-$(date +%Y%m%dT%H%M%SZ).txt"

mkdir -p "$MGDIR" "$EXTRACT_DIR"

run() {
  echo "### $* ###" | tee -a "$FINDINGS"
  "$@" 2>&1 | tee -a "$FINDINGS"
  echo "" | tee -a "$FINDINGS"
}

extract_and_find_mustgather_dir() {
  local tgz="$1"
  local dest="$2"
  mkdir -p "$dest"
  tar xzf "$tgz" -C "$dest" 2>/dev/null || true
  find "$dest" -name "._*" -delete 2>/dev/null || true
  # The real must-gather content lives one level under a directory
  # named inspect.local.* or quay-io-...-must-gather-rhel9-... (or
  # similar vendor-tagged name) - find the first such directory.
  find "$dest" -maxdepth 3 -type d \( -iname "inspect.local.*" -o -iname "*must-gather*" -o -iname "*-must-gather-rhel*" \) | head -1
}

echo "### Extracting and loading general must-gather: ${GENERAL_TGZ} ###" | tee "$FINDINGS"
GENERAL_DIR=$(extract_and_find_mustgather_dir "$GENERAL_TGZ" "${EXTRACT_DIR}/general")
if [ -z "$GENERAL_DIR" ]; then
  echo "Could not locate must-gather content under ${EXTRACT_DIR}/general - inspect manually." | tee -a "$FINDINGS"
  exit 1
fi
omc mg delete -a >/dev/null 2>&1 || true
omc use "$GENERAL_DIR" 2>&1 | tee -a "$FINDINGS"
echo "" | tee -a "$FINDINGS"

echo "=========================================="
echo "GENERAL CLUSTER HEALTH"
echo "=========================================="
run omc get co
run omc get nodes -o wide
run omc certs inspect
run omc get proxy cluster -o yaml
run omc get network.config cluster -o yaml
run omc etcd health
run omc etcd status

if [ -n "$VIRT_TGZ" ]; then
  echo "### Extracting and loading OpenShift Virtualization must-gather: ${VIRT_TGZ} ###" | tee -a "$FINDINGS"
  VIRT_DIR=$(extract_and_find_mustgather_dir "$VIRT_TGZ" "${EXTRACT_DIR}/virt")
  if [ -z "$VIRT_DIR" ]; then
    echo "Could not locate must-gather content under ${EXTRACT_DIR}/virt - inspect manually." | tee -a "$FINDINGS"
    exit 1
  fi
  omc mg delete -a >/dev/null 2>&1 || true
  omc use "$VIRT_DIR" 2>&1 | tee -a "$FINDINGS"
  echo "" | tee -a "$FINDINGS"

  echo "=========================================="
  echo "OPENSHIFT VIRTUALIZATION"
  echo "=========================================="
  run omc get csv -n openshift-cnv
  run omc get hco -n openshift-cnv -o yaml
  run omc get kubevirt -n openshift-cnv -o yaml
  run omc get vm -A
  run omc get vmi -A
  run omc get dv -A
  run omc get pvc -A
  run omc get storageclass
  run omc get networkattachmentdefinitions -A
  run omc get nncp
  run omc get providers.forklift.konveyor.io -A
  run omc describe hco kubevirt-hyperconverged -n openshift-cnv
fi

echo "=========================================="
echo "Findings saved to: ${FINDINGS}"
echo "=========================================="
