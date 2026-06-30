#!/usr/bin/env bash
# Shared helpers + paths. Sourced by every script. Not meant to run directly.

# --- Resolve repo root regardless of where we're invoked from ---
# shellcheck disable=SC2155
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export VENDOR_DIR="${REPO_ROOT}/vendor"
export CERTS_DIR="${REPO_ROOT}/certs"
export CONFIG_DIR="${REPO_ROOT}/config"
export MANIFEST="${VENDOR_DIR}/manifest.env"
export SHA256SUMS="${VENDOR_DIR}/SHA256SUMS"

# --- Pretty logging ---
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_RST=""
fi
log()   { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Load the pinned manifest into the environment.
load_manifest() {
  [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
  # shellcheck disable=SC1090
  . "$MANIFEST"
}

# Load user config (config.env). Dies with guidance if missing.
load_config() {
  local cfg="${REPO_ROOT}/config.env"
  if [ -f "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg"
  else
    die "config.env not found. Copy config.env.example to config.env and edit it."
  fi
  : "${AWX_HOSTNAME:?AWX_HOSTNAME must be set in config.env}"
  : "${AWX_ADMIN_PASSWORD:?AWX_ADMIN_PASSWORD must be set in config.env}"
  export AWX_NAMESPACE="${AWX_NAMESPACE:-awx}"
  export AWX_NAME="${AWX_NAME:-awx}"
  export AWX_NODEPORT="${AWX_NODEPORT:-30080}"
  export AWX_POSTGRES_STORAGE="${AWX_POSTGRES_STORAGE:-8Gi}"
  export AWX_PROJECTS_STORAGE="${AWX_PROJECTS_STORAGE:-8Gi}"
  export AWX_SERVICE_TYPE="${AWX_SERVICE_TYPE:-nodeport}"
  export CERT_FILE="${CERT_FILE:-${CERTS_DIR}/cert.pem}"
  export KEY_FILE="${KEY_FILE:-${CERTS_DIR}/key.pem}"
  # Resolve relative cert paths against the repo root so CWD doesn't matter.
  case "$CERT_FILE" in /*) ;; *) CERT_FILE="${REPO_ROOT}/${CERT_FILE#./}";; esac
  case "$KEY_FILE"  in /*) ;; *) KEY_FILE="${REPO_ROOT}/${KEY_FILE#./}";;  esac
  export CERT_FILE KEY_FILE
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "this step must run as root (use sudo)."
}

# k3s ships its own kubectl. Use it so we don't depend on a separate binary.
kubectl() { k3s kubectl "$@"; }
export -f kubectl 2>/dev/null || true
