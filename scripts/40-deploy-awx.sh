#!/usr/bin/env bash
# Create the admin-password secret and the AWX custom resource. The operator
# reconciles it into a running AWX (web, task, postgres, redis pods).
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_manifest
load_config
require_root

# --- Admin password secret (referenced by the AWX CR via admin_password_secret) ---
SECRET_NAME="${AWX_NAME}-admin-password"
log "Creating/updating admin password secret ${SECRET_NAME}"
k3s kubectl -n "${AWX_NAMESPACE}" create secret generic "${SECRET_NAME}" \
  --from-literal=password="${AWX_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | k3s kubectl apply -f -

# --- Optional: TLS secret for ingress termination ---
TLS_SECRET_LINE=""
if [ "${AWX_SERVICE_TYPE}" = "ingress" ] && [ "${AWX_INGRESS_TLS:-false}" = "true" ]; then
  TLS_SECRET="${AWX_NAME}-tls"
  log "Creating TLS secret ${TLS_SECRET}"
  k3s kubectl -n "${AWX_NAMESPACE}" create secret tls "${TLS_SECRET}" \
    --cert="${CERT_FILE}" --key="${KEY_FILE}" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
  TLS_SECRET_LINE="  ingress_tls_secret: ${TLS_SECRET}"
fi

# --- Render the AWX custom resource ---
log "Rendering AWX custom resource"
out="${CONFIG_DIR}/awx.rendered.yaml"
sed \
  -e "s|__AWX_NAME__|${AWX_NAME}|g" \
  -e "s|__AWX_NAMESPACE__|${AWX_NAMESPACE}|g" \
  -e "s|__AWX_HOSTNAME__|${AWX_HOSTNAME}|g" \
  -e "s|__AWX_NODEPORT__|${AWX_NODEPORT}|g" \
  -e "s|__AWX_SERVICE_TYPE__|${AWX_SERVICE_TYPE}|g" \
  -e "s|__SECRET_NAME__|${SECRET_NAME}|g" \
  -e "s|__AWX_IMAGE__|${AWX_IMAGE_NAME}|g" \
  -e "s|__AWX_IMAGE_VERSION__|${AWX_IMAGE_VERSION}|g" \
  -e "s|__AWX_EE_IMAGE__|${AWX_EE_IMAGE}|g" \
  -e "s|__AWX_INIT_IMAGE__|${AWX_INIT_IMAGE}|g" \
  -e "s|__AWX_POSTGRES_IMAGE__|${AWX_POSTGRES_IMAGE_NAME}|g" \
  -e "s|__AWX_POSTGRES_VERSION__|${AWX_POSTGRES_IMAGE_VERSION}|g" \
  -e "s|__AWX_REDIS_IMAGE__|${AWX_REDIS_IMAGE_NAME}|g" \
  -e "s|__AWX_REDIS_VERSION__|${AWX_REDIS_IMAGE_VERSION}|g" \
  -e "s|__AWX_POSTGRES_STORAGE__|${AWX_POSTGRES_STORAGE}|g" \
  -e "s|__AWX_PROJECTS_STORAGE__|${AWX_PROJECTS_STORAGE}|g" \
  "${CONFIG_DIR}/awx.yaml.tmpl" > "$out"
# The TLS line lives on its own placeholder line: substitute it when in use,
# otherwise delete the line entirely so no blank line is left behind.
if [ -n "$TLS_SECRET_LINE" ]; then
  sed -i "s|__TLS_SECRET_LINE__|${TLS_SECRET_LINE}|" "$out"
else
  sed -i '/__TLS_SECRET_LINE__/d' "$out"
fi

log "Applying AWX custom resource"
k3s kubectl apply -f "$out" || die "failed to apply AWX CR"

cat <<EOF

$(ok "AWX custom resource applied. The operator is now reconciling it.")

  Watch:    sudo k3s kubectl -n ${AWX_NAMESPACE} get pods -w
  Status:   sudo k3s kubectl -n ${AWX_NAMESPACE} get awx ${AWX_NAME}

When all pods are Running/Completed, reach AWX at:
EOF
if [ "${AWX_SERVICE_TYPE}" = "nodeport" ]; then
  echo "  http://<this-host>:${AWX_NODEPORT}/   (or http://${AWX_HOSTNAME}:${AWX_NODEPORT}/)"
else
  echo "  https://${AWX_HOSTNAME}/   (via ingress)"
fi
cat <<EOF
  User:     admin
  Password: (the AWX_ADMIN_PASSWORD from config.env)

First reconcile pulls nothing from the internet but can take several minutes
while postgres initializes and migrations run.
EOF
