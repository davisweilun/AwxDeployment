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
# Image export needs a tool that can pull OCI images:
#   - skopeo (preferred; no daemon required), OR
#   - docker (uses the local daemon).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
. "${SCRIPT_DIR}/scripts/lib.sh"
load_manifest

need_cmd curl
need_cmd sha256sum

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
  if command -v skopeo >/dev/null 2>&1; then
    # Export as an OCI archive: 'k3s ctr images import' ingests these reliably,
    # whereas skopeo's docker-archive output can fail import with
    # "content digest ... not found". The ':${ref}' adds the human tag.
    skopeo copy --override-os linux --override-arch amd64 \
      "docker://${pull}" "oci-archive:${dest}:${ref}" \
      || die "skopeo copy failed for $pull"
  elif command -v docker >/dev/null 2>&1; then
    docker pull --platform linux/amd64 "$pull" || die "docker pull failed for $pull"
    if [ "$pull" != "$ref" ]; then
      docker tag "$pull" "$ref" || die "docker tag failed: $pull -> $ref"
    fi
    # With Docker's containerd image store, 'docker save' writes the FULL
    # multi-arch index. Importing that into k3s containerd fails with
    # "content digest <other-arch>: not found". Save a single platform when the
    # installed docker supports 'docker save --platform' (Engine v28+); older
    # docker without the containerd store already holds only amd64, so a plain
    # save is fine. If you hit the digest error on an old docker WITH the
    # containerd store, disable it: set features.containerd-snapshotter=false in
    # /etc/docker/daemon.json and restart docker (see README).
    if docker save --help 2>&1 | grep -q -- '--platform'; then
      docker save --platform linux/amd64 -o "$dest" "$ref" \
        || die "docker save failed for $ref"
    else
      docker save -o "$dest" "$ref" || die "docker save failed for $ref"
    fi
  else
    die "need 'skopeo' or 'docker' to export images; install one and re-run."
  fi
}

log "Saving AWX container images (amd64)"
INIT_REF="${AWX_INIT_IMAGE_NAME}:${AWX_INIT_IMAGE_VERSION}"
for img in $AWX_IMAGES; do
  if [ "$img" = "$INIT_REF" ] && [ -n "${AWX_INIT_IMAGE_DIGEST:-}" ]; then
    # Pin the init image by digest, but save it under its :stream9 tag.
    save_image "$img" "${AWX_INIT_IMAGE_NAME}@${AWX_INIT_IMAGE_DIGEST}"
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
