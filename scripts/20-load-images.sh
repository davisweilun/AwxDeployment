#!/usr/bin/env bash
# Import the vendored AWX container images into k3s's containerd image store,
# so the operator and AWX pods never pull from a registry.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_manifest
require_root

IMG_DIR="${VENDOR_DIR}/images"
command -v k3s >/dev/null 2>&1 || die "k3s not found; run 10-install-k3s.sh first"

shopt -s nullglob
tarballs=("${IMG_DIR}"/*.tar)
[ "${#tarballs[@]}" -ge 1 ] || die "no image tarballs in ${IMG_DIR}"

log "Importing ${#tarballs[@]} image tarball(s) into k3s containerd"
for tar in "${tarballs[@]}"; do
  log "  ctr images import $(basename "$tar")"
  # k3s ctr writes into the 'k8s.io' namespace that the kubelet reads from.
  k3s ctr images import "$tar" >/dev/null \
    || die "failed to import $(basename "$tar")"
done

# Sanity check: the operator + AWX images should now be present.
present=$(k3s ctr images ls -q 2>/dev/null | wc -l | tr -d ' ')
ok "Image import complete (${present} images now in containerd)."
store="$(k3s ctr images ls -q 2>/dev/null)"
for img in $AWX_IMAGES; do
  # Match on '<last-path-segment>:<tag>' so containerd's docker.io/library/...
  # normalization doesn't produce false negatives.
  needle="${img##*/}"
  if printf '%s\n' "$store" | grep -qF "$needle"; then
    ok "  present: $img"
  else
    warn "  NOT found in store: $img (tag mismatch? check manifest.env vs the saved tarball)"
  fi
done
