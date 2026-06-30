#!/usr/bin/env bash
# Tear down AWX. By default removes the AWX instance + operator but leaves k3s
# and its data. --purge also uninstalls k3s entirely (removing ALL cluster data).
#   sudo ./uninstall.sh           # delete AWX CR + operator namespace
#   sudo ./uninstall.sh --purge   # also run k3s-uninstall.sh (nukes the cluster)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"
require_root

# Teardown only needs the namespace + instance name. Use config.env if present,
# otherwise fall back to defaults so you can still uninstall after deleting it.
if [ -f "${REPO_ROOT}/config.env" ]; then
  # shellcheck disable=SC1091
  . "${REPO_ROOT}/config.env"
fi
AWX_NAMESPACE="${AWX_NAMESPACE:-awx}"
AWX_NAME="${AWX_NAME:-awx}"

if command -v k3s >/dev/null 2>&1; then
  if k3s kubectl get awx "${AWX_NAME}" -n "${AWX_NAMESPACE}" >/dev/null 2>&1; then
    log "Deleting AWX instance ${AWX_NAME}"
    k3s kubectl delete awx "${AWX_NAME}" -n "${AWX_NAMESPACE}" --ignore-not-found
  fi
  log "Deleting namespace ${AWX_NAMESPACE} (operator + PVCs)"
  k3s kubectl delete namespace "${AWX_NAMESPACE}" --ignore-not-found || warn "namespace delete failed"
else
  warn "k3s not found; nothing to delete in-cluster"
fi

if [ "${1:-}" = "--purge" ]; then
  if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
    warn "PURGE: uninstalling k3s and ALL cluster data"
    /usr/local/bin/k3s-uninstall.sh || warn "k3s-uninstall.sh failed"
    ok "k3s uninstalled."
  else
    warn "k3s-uninstall.sh not found; k3s may already be gone"
  fi
else
  ok "AWX removed. k3s left running. Use --purge to also uninstall k3s."
fi
