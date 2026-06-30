#!/usr/bin/env bash
# =============================================================================
# install.sh — top-level orchestrator. Run on the Ubuntu 24.04 TARGET server.
#
#   sudo ./install.sh
#
# Prereqs:
#   1. Vendored assets present in ./vendor   (run ./fetch-assets.sh beforehand)
#   2. ./config.env created from config.env.example and edited
#   3. (optional) TLS cert + key in ./certs if AWX_SERVICE_TYPE=ingress + TLS
#
# Idempotent: each step skips work that is already done.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/scripts/lib.sh"

require_root

steps=(
  "scripts/00-preflight.sh"
  "scripts/10-install-k3s.sh"
  "scripts/20-load-images.sh"
  "scripts/30-deploy-operator.sh"
  "scripts/40-deploy-awx.sh"
)

log "AWX offline installer (k3s + awx-operator) — Ubuntu 24.04"
for s in "${steps[@]}"; do
  echo
  log "==== ${s} ===="
  bash "${SCRIPT_DIR}/${s}"
done

echo
ok "All steps finished. AWX is being reconciled by the operator."
echo "Watch progress with:  sudo k3s kubectl -n \$AWX_NAMESPACE get pods -w"
