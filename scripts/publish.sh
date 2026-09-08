#!/usr/bin/env bash
#
# publish.sh — the single, serialized write path of techprimate/publisher.
#
# Turns a project's GitHub Release into signed rpm/deb/Homebrew/raw packages and
# publishes them to the R2-backed registry at packages.techprimate.app. Convergent and
# overwrite-safe: re-running for the same (SOURCE_REPO, TAG) ends in the same
# registry state. Published versions are immutable — a rerun that would change an
# already-published artifact fails loudly rather than overwriting it.
#
# Required environment (set by .github/workflows/publish.yml):
#   SOURCE_REPO            e.g. techprimate/apple-docs
#   TAG                    e.g. v1.3.0
#   GH_TOKEN              TECHPRIMATE_RELEASE_BOT app token (contents:read on SOURCE_REPO)
#   R2_BUCKET             techprimate-release-registry
#   R2_S3_ENDPOINT        https://<account>.r2.cloudflarestorage.com
#   REGISTRY_DOMAIN       packages.techprimate.app
#   CLOUDFLARE_ZONE_ID    zone id for the cache purge
#   CLOUDFLARE_API_TOKEN  token authorised to purge the zone cache
#   AWS_ACCESS_KEY_ID     R2 access key id   (from CLOUDFLARE_ACCESS_KEY_ID)
#   AWS_SECRET_ACCESS_KEY R2 secret          (from CLOUDFLARE_SECRET_ACCESS_KEY)
#   GPG_PRIVATE_KEY       armored private signing key
#   GPG_PASSPHRASE        passphrase for the signing key
#
# The Homebrew formula is published separately by .github/workflows/_homebrew.yml.
#
set -euo pipefail

# --- Config / constants -------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "${PUBLISHER_TEST_MODE:-}" = "1" ]; then
  SOURCE_REPO="${SOURCE_REPO:-techprimate/test}"
  TAG="${TAG:-v0.0.0}"
  R2_BUCKET="${R2_BUCKET:-test-bucket}"
  R2_S3_ENDPOINT="${R2_S3_ENDPOINT:-https://example.invalid}"
fi
PKG="${SOURCE_REPO##*/}"          # techprimate/apple-docs -> apple-docs
VERSION="${TAG#v}"                # v1.3.0 -> 1.3.0
SUITE="stable"

export AWS_DEFAULT_REGION="auto"  # R2 ignores region but the CLI requires one.
export AWS_REQUEST_CHECKSUM_CALCULATION="when_required"  # R2 rejects aws-chunked default checksums.

# nfpm arch (left) drives the rpm $basearch dir (right). Go arch == nfpm arch here.
declare -A RPM_BASEARCH=( [amd64]=x86_64 [arm64]=aarch64 )
ARCHES=(amd64 arm64)

WORK="$(mktemp -d)"
MIRROR="${WORK}/mirror/${PKG}"    # local mirror of s3://$R2_BUCKET/$PKG (rpm + deb)
BUILD="${WORK}/build"             # freshly built artifacts for THIS run
export GNUPGHOME="${WORK}/gnupg"
mkdir -p "$MIRROR" "$BUILD" "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

s3() { aws s3 --endpoint-url "$R2_S3_ENDPOINT" "$@"; }
s3api() { aws s3api --endpoint-url "$R2_S3_ENDPOINT" "$@"; }

render_nfpm_config() {  # ARCH OUT
  local arch="$1" out="$2"
  ARCH="$arch" GOARCH="$arch" VERSION="$VERSION" MTIME="$MTIME" \
    envsubst < "${REPO_ROOT}/packages/${PKG}/nfpm.yaml" > "$out"
}

# ensure_immutable LOCAL_FILE S3_KEY
# Published versions are immutable: if the key already exists with different
# bytes, the tag was moved/force-pushed — fail loudly instead of overwriting a
# version consumers may already have cached.
ensure_immutable() {
  local local_file="$1" key="$2" tmp
  s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null 2>&1 || return 0
  tmp="$(mktemp)"
  s3 cp "s3://${R2_BUCKET}/${key}" "$tmp" >/dev/null
  if ! cmp -s "$local_file" "$tmp"; then
    rm -f "$tmp"
    fail "immutability violation: s3://${R2_BUCKET}/${key} already published with different content (tag moved?). Refusing to overwrite."
  fi
  rm -f "$tmp"
}

rpm_payload_sha256() { # RPM_FILE
  local rpm_file="$1" digest
  if ! digest="$(rpm2cpio "$rpm_file" | sha256sum | awk '{print $1}')"; then
    fail "immutability check failed: could not read RPM payload from ${rpm_file}"
  fi
  printf '%s\n' "$digest"
}

# RPM signatures and package headers can include run-specific data, so a rerun
# cannot safely byte-compare a freshly built RPM with an already-published RPM.
# Compare the installed payload instead; when it matches, keep the existing
# signed package bytes.
use_existing_rpm_if_same_content() {  # UNSIGNED_RPM S3_KEY OUT_FILE
  local unsigned_file="$1" key="$2" out_file="$3" tmp local_payload remote_payload
  s3api head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null 2>&1 || return 1

  tmp="$(mktemp --suffix=.rpm)"
  s3 cp "s3://${R2_BUCKET}/${key}" "$tmp" >/dev/null
  local_payload="$(rpm_payload_sha256 "$unsigned_file")"
  remote_payload="$(rpm_payload_sha256 "$tmp")"

  if [ "$local_payload" != "$remote_payload" ]; then
    rm -f "$tmp"
    fail "immutability violation: s3://${R2_BUCKET}/${key} already published with different RPM payload content (tag moved?). Refusing to overwrite."
  fi

  cp -f "$tmp" "$out_file"
  rm -f "$tmp"
  return 0
}

if [ "${PUBLISHER_TEST_MODE:-}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
  fi
  exit 0
fi

# detached, armored signature with the loaded signing key
gpg_sign_detached() {  # SRC DST
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
      --digest-algo sha256 -u "$GPG_KEY_ID" --armor --detach-sign -o "$2" "$1"
}

# === 0. GPG setup =============================================================
log "Importing signing key"
printf '%s' "$GPG_PRIVATE_KEY" | gpg --batch --import
GPG_KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
[ -n "$GPG_KEY_ID" ] || fail "no secret key found after import"
PASS_FILE="${WORK}/passphrase"
printf '%s' "$GPG_PASSPHRASE" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# rpm signing macros (loopback pinentry so it is non-interactive)
cat > "$HOME/.rpmmacros" <<EOF
%_gpg_name ${GPG_KEY_ID}
%__gpg /usr/bin/gpg
%__gpg_sign_cmd %{__gpg} gpg --no-verbose --no-armor --batch --yes --pinentry-mode loopback --passphrase-file ${PASS_FILE} --digest-algo sha256 -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
EOF

# === 1. Download release binaries ============================================
log "Downloading ${SOURCE_REPO}@${TAG} release assets"
mkdir -p "${BUILD}/dist"
gh release download "$TAG" --repo "$SOURCE_REPO" --dir "${BUILD}/dist" \
  --pattern "${PKG}-linux-*" --pattern "${PKG}-darwin-*" --clobber
for f in "${PKG}-linux-amd64" "${PKG}-linux-arm64" "${PKG}-darwin-amd64" "${PKG}-darwin-arm64"; do
  [ -f "${BUILD}/dist/${f}" ] || fail "missing release asset: ${f}"
  chmod +x "${BUILD}/dist/${f}"
done

# Reproducible builds: pin timestamps to the tag's commit date (no wall clock).
COMMIT_DATE="$(gh api "repos/${SOURCE_REPO}/commits/${TAG}" --jq '.commit.committer.date')"
export SOURCE_DATE_EPOCH MTIME
SOURCE_DATE_EPOCH="$(date -u -d "$COMMIT_DATE" +%s)"
MTIME="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (${MTIME})"

# === 2. Pull existing index state ============================================
# rpm/deb metadata is regenerated from the full set of packages, so the existing
# package bodies must be present locally. They are immutable and small at our
# release cadence; aws s3 sync only fetches what is missing. (bin/** needs no
# index, so it is not mirrored — only the current version is immutability-checked.)
log "Mirroring existing stable rpm/deb tree for ${PKG}"
s3 sync "s3://${R2_BUCKET}/${PKG}/rpm/stable" "${MIRROR}/rpm/stable" --no-progress 2>/dev/null || true
s3 sync "s3://${R2_BUCKET}/${PKG}/deb/pool/stable" "${MIRROR}/deb/pool/stable" --no-progress 2>/dev/null || true
s3 sync "s3://${R2_BUCKET}/${PKG}/deb/dists/${SUITE}" "${MIRROR}/deb/dists/${SUITE}" --no-progress 2>/dev/null || true

# === 3. Build + sign rpm =====================================================
for arch in "${ARCHES[@]}"; do
  basearch="${RPM_BASEARCH[$arch]}"
  outdir="${MIRROR}/rpm/stable/${basearch}"
  nfpm_config="${BUILD}/nfpm-${arch}.yaml"
  mkdir -p "$outdir"
  render_nfpm_config "$arch" "$nfpm_config"
  log "Building rpm (stable/${basearch})"
  ( cd "$BUILD" && nfpm pkg --packager rpm --config "$nfpm_config" --target "$BUILD/" )
  rpm_matches=( "${BUILD}/"*."${basearch}".rpm )   # exactly one per basearch
  rpmfile="${rpm_matches[-1]}"
  rpm_key="${PKG}/rpm/stable/${basearch}/$(basename "$rpmfile")"
  if use_existing_rpm_if_same_content "$rpmfile" "$rpm_key" "${outdir}/$(basename "$rpmfile")"; then
    log "Using already-published signed rpm ($(basename "$rpmfile"))"
  else
    log "Signing $(basename "$rpmfile")"
    rpm --addsign "$rpmfile" >/dev/null
    ensure_immutable "$rpmfile" "$rpm_key"
    cp -f "$rpmfile" "$outdir/"
  fi
done

# === 4. Build deb ============================================================
# deb packages are verified by apt via the signed InRelease (step 7), the apt
# standard — so the .deb bodies themselves are not individually signed.
mkdir -p "${MIRROR}/deb/pool/stable"
for arch in "${ARCHES[@]}"; do
  nfpm_config="${BUILD}/nfpm-${arch}.yaml"
  render_nfpm_config "$arch" "$nfpm_config"
  log "Building deb (stable/${arch})"
  ( cd "$BUILD" && nfpm pkg --packager deb --config "$nfpm_config" --target "$BUILD/" )
  deb_matches=( "${BUILD}/"*"${arch}".deb )   # exactly one per arch
  debfile="${deb_matches[-1]}"
  ensure_immutable "$debfile" "${PKG}/deb/pool/stable/$(basename "$debfile")"
  cp -f "$debfile" "${MIRROR}/deb/pool/stable/"
done

# === 5. Raw binaries =========================================================
log "Staging raw binaries (bin/v${VERSION})"
bindir="${BUILD}/bin/v${VERSION}"
mkdir -p "$bindir"
for f in "${PKG}-linux-amd64" "${PKG}-linux-arm64" "${PKG}-darwin-amd64" "${PKG}-darwin-arm64"; do
  cp -f "${BUILD}/dist/${f}" "${bindir}/${f}"
  ensure_immutable "${bindir}/${f}" "${PKG}/bin/v${VERSION}/${f}"
done

# === 6. Index rpm (createrepo_c) + deb (apt-ftparchive) ======================
for arch in "${ARCHES[@]}"; do
  basearch="${RPM_BASEARCH[$arch]}"
  log "Indexing rpm (stable/${basearch})"
  if [ -d "${MIRROR}/rpm/stable/${basearch}/repodata" ]; then
    createrepo_c --update "${MIRROR}/rpm/stable/${basearch}" >/dev/null
  else
    createrepo_c "${MIRROR}/rpm/stable/${basearch}" >/dev/null
  fi
done

log "Indexing deb (${SUITE})"
debroot="${MIRROR}/deb"
for arch in "${ARCHES[@]}"; do
  mkdir -p "${debroot}/dists/${SUITE}/main/binary-${arch}"
  # Index only the stable pool so package filenames stay under pool/stable/.
  ( cd "$debroot" && apt-ftparchive --arch "$arch" packages "pool/${SUITE}" ) \
    > "${debroot}/dists/${SUITE}/main/binary-${arch}/Packages"
  gzip -kf "${debroot}/dists/${SUITE}/main/binary-${arch}/Packages"
done

# === 7. Sign metadata ========================================================
for arch in "${ARCHES[@]}"; do
  basearch="${RPM_BASEARCH[$arch]}"
  log "Signing repomd.xml (stable/${basearch})"
  gpg_sign_detached "${MIRROR}/rpm/stable/${basearch}/repodata/repomd.xml" \
                    "${MIRROR}/rpm/stable/${basearch}/repodata/repomd.xml.asc"
done

log "Generating + signing apt Release/InRelease"
cat > "${WORK}/apt-release.conf" <<EOF
APT::FTPArchive::Release::Origin "techprimate";
APT::FTPArchive::Release::Label "techprimate";
APT::FTPArchive::Release::Suite "${SUITE}";
APT::FTPArchive::Release::Codename "${SUITE}";
APT::FTPArchive::Release::Architectures "${ARCHES[*]}";
APT::FTPArchive::Release::Components "main";
EOF
reldir="${debroot}/dists/${SUITE}"
apt-ftparchive -c "${WORK}/apt-release.conf" release "$reldir" > "${reldir}/Release"
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASS_FILE" \
    --digest-algo sha256 -u "$GPG_KEY_ID" --clearsign -o "${reldir}/InRelease" "${reldir}/Release"
gpg_sign_detached "${reldir}/Release" "${reldir}/Release.gpg"

# Public key + source files (convergent — re-uploaded every run).
gpg --armor --export "$GPG_KEY_ID" > "${BUILD}/RPM-GPG-KEY-techprimate"

# === 8. Publish — artifacts BEFORE the metadata that references them ==========
# A failure between the two leaves stale-but-valid metadata pointing only at
# already-published packages, never a dangling reference.
log "Uploading raw binaries"
s3 sync "${BUILD}/bin" "s3://${R2_BUCKET}/${PKG}/bin" --no-progress

log "Uploading rpm/deb package bodies"
s3 sync "${MIRROR}/rpm/stable" "s3://${R2_BUCKET}/${PKG}/rpm/stable" --no-progress --exclude "*/repodata/*"
s3 sync "${MIRROR}/deb/pool/stable" "s3://${R2_BUCKET}/${PKG}/deb/pool/stable" --no-progress

log "Uploading index metadata"
s3 sync "${MIRROR}/rpm/stable" "s3://${R2_BUCKET}/${PKG}/rpm/stable" --no-progress
s3 sync "${MIRROR}/deb/dists/${SUITE}" "s3://${R2_BUCKET}/${PKG}/deb/dists/${SUITE}" --no-progress

log "Uploading shared registry files"
s3 cp "${BUILD}/RPM-GPG-KEY-techprimate" "s3://${R2_BUCKET}/RPM-GPG-KEY-techprimate"
s3 cp "${REPO_ROOT}/repo/techprimate.repo" "s3://${R2_BUCKET}/techprimate.repo"
s3 cp "${REPO_ROOT}/repo/techprimate.sources" "s3://${R2_BUCKET}/techprimate.sources"

# === 9. Purge metadata from the edge cache (idempotent) ======================
# Only stable-named metadata needs purging; content-addressed repodata files get
# fresh names each run and are never cache-stale.
log "Purging Cloudflare cache for metadata paths"
purge_urls=()
for arch in "${ARCHES[@]}"; do
  basearch="${RPM_BASEARCH[$arch]}"
  base="https://${REGISTRY_DOMAIN}/${PKG}/rpm/stable/${basearch}/repodata"
  purge_urls+=( "\"${base}/repomd.xml\"" "\"${base}/repomd.xml.asc\"" )
  dbase="https://${REGISTRY_DOMAIN}/${PKG}/deb/dists/${SUITE}/main/binary-${arch}"
  purge_urls+=( "\"${dbase}/Packages\"" "\"${dbase}/Packages.gz\"" )
done
relbase="https://${REGISTRY_DOMAIN}/${PKG}/deb/dists/${SUITE}"
purge_urls+=( "\"${relbase}/Release\"" "\"${relbase}/Release.gpg\"" "\"${relbase}/InRelease\"" )
purge_urls+=( "\"https://${REGISTRY_DOMAIN}/techprimate.repo\"" "\"https://${REGISTRY_DOMAIN}/techprimate.sources\"" "\"https://${REGISTRY_DOMAIN}/RPM-GPG-KEY-techprimate\"" )
files_json="$(IFS=,; echo "${purge_urls[*]}")"
curl -fsS -X POST \
  "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"files\":[${files_json}]}" >/dev/null

log "Published ${PKG} ${VERSION} to ${REGISTRY_DOMAIN}"
