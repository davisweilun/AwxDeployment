#!/usr/bin/env bash
# =============================================================================
# fetch-assets.sh
# Downloads the pinned k3s release, the awx-operator source, and saves the AWX
# container images into ./vendor, then writes vendor/SHA256SUMS.
#
# Run this ONCE on any machine with internet access. The resulting repo is then
# a fully self-contained, air-gap-ready bundle. This script DOES NOT install
# anything on a cluster — it only downloads and exports images.
#
# Image export uses docker (pull + save). If docker isn't installed this script
# installs it automatically via apt (Ubuntu/Debian) and starts its daemon.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/scripts/lib.sh"
load_manifest

need_cmd curl
need_cmd sha256sum

# Run docker as root via sudo when we're not already root (the daemon socket is
# root-owned). apt installs below also need it.
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
DOCKER="docker"; [ "$(id -u)" -eq 0 ] || DOCKER="sudo docker"

# Ensure docker is installed and its daemon is reachable; install it if missing.
ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "docker present: $(docker --version 2>/dev/null)"
  else
    warn "docker not found — installing it (needed to export the AWX images)"
    command -v apt-get >/dev/null 2>&1 \
      || die "docker is missing and auto-install requires apt-get (Ubuntu/Debian); install docker manually and re-run."
    $SUDO apt-get update -y            || die "apt-get update failed"
    $SUDO apt-get install -y docker.io || die "apt-get install docker.io failed"
    command -v docker >/dev/null 2>&1  || die "docker still not on PATH after install"
    command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker 2>/dev/null || true
    ok "docker installed: $(docker --version 2>/dev/null)"
  fi
  # Verify the daemon answers (start it if it isn't running).
  if ! $DOCKER info >/dev/null 2>&1; then
    warn "docker daemon not reachable — trying to start it"
    command -v systemctl >/dev/null 2>&1 && $SUDO systemctl enable --now docker 2>/dev/null || true
    $DOCKER info >/dev/null 2>&1 \
      || die "docker is installed but its daemon isn't reachable; start it (sudo systemctl start docker) and re-run."
  fi
}
ensure_docker

K3S_DIR="${VENDOR_DIR}/k3s"
OP_DIR="${VENDOR_DIR}/operator"
IMG_DIR="${VENDOR_DIR}/images"
mkdir -p "$K3S_DIR" "$OP_DIR" "$IMG_DIR"

# download <url> <dest> — resumable, skips if already complete.
download() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then
    ok "already present: $(basename "$dest")"
    return 0
  fi
  log "downloading $(basename "$dest")"
  curl -fSL --retry 3 --retry-delay 2 -C - -o "$dest" "$url" \
    || die "download failed: $url"
}

# --- k3s release (binary + airgap images + install script) ---
# The '+' in the version tag must be percent-encoded for the GitHub URL.
enc_base="${K3S_BASE_URL//+/%2B}"
log "Fetching k3s ${K3S_VERSION}"
download "${enc_base}/${K3S_BINARY}"          "${K3S_DIR}/${K3S_BINARY}"
download "${enc_base}/${K3S_AIRGAP_IMAGES}"   "${K3S_DIR}/${K3S_AIRGAP_IMAGES}"
download "${K3S_INSTALL_SCRIPT_URL}"          "${K3S_DIR}/install.sh"
chmod +x "${K3S_DIR}/${K3S_BINARY}" "${K3S_DIR}/install.sh"

# --- awx-operator source tree (kustomize builds from this offline) ---
log "Fetching awx-operator ${AWX_OPERATOR_VERSION} source"
download "$AWX_OPERATOR_SRC_URL" "${OP_DIR}/${AWX_OPERATOR_SRC_TGZ}"

# --- container images -> docker-archive tarballs in vendor/images ---
# image_to_filename quay.io/ansible/awx:24.6.1 -> quay.io_ansible_awx_24.6.1.tar
image_to_filename() { echo "$1" | tr '/:' '__'; }

# save_image <tag-ref> [pull-ref]
# Saves a docker-archive tarball tagged as <tag-ref>. If <pull-ref> is given
# (e.g. an immutable name@sha256:... digest) the image is pulled from there but
# re-tagged to <tag-ref> in the archive, so consumers reference a clean tag.
save_image() {
  local ref="$1" pull="${2:-$1}"
  local dest="$IMG_DIR/$(image_to_filename "$ref").tar"
  if [ -s "$dest" ]; then
    ok "image already saved: $(basename "$dest")"
    return 0
  fi
  if [ "$pull" = "$ref" ]; then log "pulling + saving $ref"
  else                          log "pulling $pull -> saving as $ref"; fi
  $DOCKER pull --platform linux/amd64 "$pull" || die "docker pull failed for $pull"
  if [ "$pull" != "$ref" ]; then
    $DOCKER tag "$pull" "$ref" || die "docker tag failed: $pull -> $ref"
  fi
  # With Docker's containerd image store, 'docker save' writes the FULL
  # multi-arch index. Importing that into k3s containerd fails with
  # "content digest <other-arch>: not found". Save a single platform when the
  # installed docker supports 'docker save --platform' (Engine v28+); older
  # docker without the containerd store already holds only amd64, so a plain
  # save is fine. If you hit the digest error on an old docker WITH the
  # containerd store, disable it: set features.containerd-snapshotter=false in
  # /etc/docker/daemon.json and restart docker (see README).
  # Redirect via the shell (not 'docker -o') so the tarball is owned by the
  # current user even when docker runs under sudo.
  if $DOCKER save --help 2>&1 | grep -q -- '--platform'; then
    $DOCKER save --platform linux/amd64 "$ref" > "$dest" \
      || die "docker save failed for $ref"
  else
    $DOCKER save "$ref" > "$dest" || die "docker save failed for $ref"
  fi
}

log "Saving AWX container images (amd64)"
INIT_REF="${AWX_INIT_IMAGE_NAME}:${AWX_INIT_IMAGE_VERSION}"
for img in $AWX_IMAGES; do
  if [ "$img" = "$INIT_REF" ] && [ -n "${AWX_INIT_IMAGE_DIGEST:-}" ]; then
    # Pin the init image by digest, but save it under its :stream9 tag.
    save_image "$img" "${AWX_INIT_IMAGE_NAME}@${AWX_INIT_IMAGE_DIGEST}"
  elif [ "$img" = "${AWX_KUBE_RBAC_PROXY_IMAGE:-}" ] && [ -n "${AWX_KUBE_RBAC_PROXY_PULL:-}" ]; then
    # gcr.io address is dead; pull from the maintainer's registry, save under
    # the gcr.io name the operator references.
    save_image "$img" "${AWX_KUBE_RBAC_PROXY_PULL}"
  else
    save_image "$img"
  fi
done

log "Generating ${SHA256SUMS}"
( cd "$VENDOR_DIR" && find k3s operator images -type f ! -name SHA256SUMS \
    | sort | xargs sha256sum > SHA256SUMS )

ok "Done. Vendored assets:"
du -sh "$K3S_DIR" "$OP_DIR" "$IMG_DIR" 2>/dev/null || true
echo
ok "SHA256SUMS written to ${SHA256SUMS}"
echo "Commit ./vendor to ship a complete offline bundle, or keep it gitignored"
echo "and re-run this script on the target side of an air gap."
