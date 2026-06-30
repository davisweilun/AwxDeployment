#!/usr/bin/env bash
# Preflight: validate host, vendored assets, certs, and config before any change.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_manifest
load_config
require_root

log "Preflight checks"

# --- Config sanity ---
case "${AWX_SERVICE_TYPE}" in
  nodeport|ingress) ;;
  *) die "AWX_SERVICE_TYPE='${AWX_SERVICE_TYPE}' is invalid; use 'nodeport' or 'ingress'" ;;
esac

# --- OS / arch ---
if [ -r /etc/os-release ]; then
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || warn "OS is '${ID:-unknown}', expected ubuntu"
  [ "${VERSION_ID:-}" = "24.04" ] || warn "Ubuntu ${VERSION_ID:-?}, this repo is pinned for 24.04"
else
  warn "/etc/os-release missing; cannot verify OS"
fi
arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
[ "$arch" = "amd64" ] || warn "arch is '$arch'; vendored assets are amd64"

# --- Vendored assets present ---
[ -s "${VENDOR_DIR}/k3s/${K3S_BINARY}" ]        || die "k3s binary missing — run fetch-assets.sh first"
[ -s "${VENDOR_DIR}/k3s/${K3S_AIRGAP_IMAGES}" ] || die "k3s airgap images missing — run fetch-assets.sh first"
[ -s "${VENDOR_DIR}/k3s/install.sh" ]           || die "k3s install.sh missing — run fetch-assets.sh first"
[ -s "${VENDOR_DIR}/operator/${AWX_OPERATOR_SRC_TGZ}" ] \
  || die "awx-operator source missing — run fetch-assets.sh first"
img_count=$(find "${VENDOR_DIR}/images" -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')
[ "$img_count" -ge 7 ] || die "expected >=7 image tarballs in vendor/images, found $img_count — run fetch-assets.sh"

# --- Checksum verification ---
if [ -f "$SHA256SUMS" ]; then
  log "Verifying SHA256 checksums"
  ( cd "$VENDOR_DIR" && sha256sum -c SHA256SUMS ) >/dev/null \
    || die "checksum verification FAILED — vendored assets are corrupt/altered"
  ok "checksums verified"
else
  warn "vendor/SHA256SUMS not found — skipping integrity check"
fi

# --- TLS certs (only required when terminating TLS at an ingress) ---
if [ "${AWX_SERVICE_TYPE}" = "ingress" ] && [ "${AWX_INGRESS_TLS:-false}" = "true" ]; then
  [ -s "$CERT_FILE" ] || die "TLS cert not found: $CERT_FILE  (see certs/README.md)"
  [ -s "$KEY_FILE" ]  || die "TLS key not found:  $KEY_FILE   (see certs/README.md)"
  if command -v openssl >/dev/null 2>&1; then
    openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || die "cert is not a valid PEM x509: $CERT_FILE"
    ok "cert looks valid: $(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null)"
  fi
else
  log "TLS certs not required for AWX_SERVICE_TYPE=${AWX_SERVICE_TYPE}; skipping cert checks"
fi

# --- Port free (best-effort), only meaningful for nodeport ---
if [ "${AWX_SERVICE_TYPE}" = "nodeport" ]; then
  if command -v ss >/dev/null 2>&1 && ss -ltn "( sport = :${AWX_NODEPORT} )" 2>/dev/null | grep -q ":${AWX_NODEPORT}"; then
    warn "port ${AWX_NODEPORT} already in use — AWX nodeport may fail to bind"
  fi
fi

ok "Preflight passed (hostname=${AWX_HOSTNAME}, namespace=${AWX_NAMESPACE}, service=${AWX_SERVICE_TYPE})"
