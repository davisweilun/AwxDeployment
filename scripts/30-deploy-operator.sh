#!/usr/bin/env bash
# Extract the awx-operator source and deploy it with kustomize (offline).
# k3s bundles kubectl with a built-in kustomize (`kubectl apply -k`).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_manifest
load_config
require_root

OP_DIR="${VENDOR_DIR}/operator"
SRC="${OP_DIR}/${AWX_OPERATOR_SRC_TGZ}"
[ -s "$SRC" ] || die "operator source not found: $SRC"

# The tarball extracts to awx-operator-<version>/
OP_HOME="${OP_DIR}/awx-operator-${AWX_OPERATOR_VERSION}"
if [ -f "${OP_HOME}/config/default/kustomization.yaml" ]; then
  ok "operator source already extracted at ${OP_HOME}"
else
  log "Extracting $(basename "$SRC")"
  tar -xzf "$SRC" -C "$OP_DIR"
  [ -f "${OP_HOME}/config/default/kustomization.yaml" ] \
    || die "unexpected operator layout; config/default/kustomization.yaml not found"
fi

# Render a top-level kustomization that points at the vendored source tree and
# pins the operator image tag (so it resolves to the image we imported offline).
log "Rendering operator kustomization (namespace=${AWX_NAMESPACE})"
RENDER_DIR="${OP_DIR}/deploy"
mkdir -p "$RENDER_DIR"
sed \
  -e "s|__OP_HOME__|${OP_HOME}|g" \
  -e "s|__AWX_NAMESPACE__|${AWX_NAMESPACE}|g" \
  -e "s|__AWX_OPERATOR_VERSION__|${AWX_OPERATOR_VERSION}|g" \
  "${CONFIG_DIR}/kustomization.yaml.tmpl" > "${RENDER_DIR}/kustomization.yaml"

log "Creating namespace ${AWX_NAMESPACE}"
k3s kubectl create namespace "${AWX_NAMESPACE}" --dry-run=client -o yaml \
  | k3s kubectl apply -f -

log "Applying awx-operator via kustomize"
k3s kubectl apply -k "${RENDER_DIR}" || die "operator kustomize apply failed"

log "Waiting for awx-operator deployment to become Available"
k3s kubectl -n "${AWX_NAMESPACE}" rollout status deploy/awx-operator-controller-manager \
  --timeout=300s || die "awx-operator did not become ready"

ok "awx-operator ${AWX_OPERATOR_VERSION} is running in namespace ${AWX_NAMESPACE}."
