#!/usr/bin/env bash
# Install a single-node k3s cluster fully offline from the vendored binary +
# airgap image tarball. Uses the official install script in SKIP_DOWNLOAD mode.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_manifest
require_root

K3S_DIR="${VENDOR_DIR}/k3s"

if command -v k3s >/dev/null 2>&1 && systemctl is-active --quiet k3s 2>/dev/null; then
  ok "k3s already installed and running: $(k3s --version | head -1)"
else
  # Pre-stage the airgap images where k3s auto-imports them on first start.
  log "Staging k3s airgap images"
  install -d /var/lib/rancher/k3s/agent/images
  install -m 0644 "${K3S_DIR}/${K3S_AIRGAP_IMAGES}" \
    /var/lib/rancher/k3s/agent/images/"${K3S_AIRGAP_IMAGES}"

  # Place the binary where the install script expects it (SKIP_DOWNLOAD).
  log "Installing k3s binary"
  install -m 0755 "${K3S_DIR}/${K3S_BINARY}" /usr/local/bin/k3s

  log "Running k3s install script (offline, SKIP_DOWNLOAD)"
  # --write-kubeconfig-mode 0644 so non-root tooling can read it.
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode 0644" \
    sh "${K3S_DIR}/install.sh" \
    || die "k3s install failed"
fi

log "Waiting for the node to become Ready"
ready=0
for _ in $(seq 1 60); do
  if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; then
    ok "k3s node Ready: $(k3s kubectl get nodes --no-headers | awk '{print $1" "$2}')"
    ready=1
    break
  fi
  sleep 5
done
[ "$ready" -eq 1 ] || die "k3s node never became Ready (still NotReady after 300s)"

ok "k3s is up. kubeconfig: /etc/rancher/k3s/k3s.yaml"
