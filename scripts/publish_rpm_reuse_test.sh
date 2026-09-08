#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

build_test_rpm() { # RELEASE OUT_FILE
  local release="$1" out_file="$2"
  local topdir spec
  topdir="${WORK}/rpmbuild-${release}"
  spec="${topdir}/SPECS/apple-docs-test.spec"
  mkdir -p "${topdir}/BUILD" "${topdir}/BUILDROOT" "${topdir}/RPMS" "${topdir}/SOURCES" "${topdir}/SPECS" "${topdir}/SRPMS"
  mkdir -p "${topdir}/tmp"
  printf '#!/usr/bin/env sh\nprintf apple-docs-test\n' > "${topdir}/SOURCES/apple-docs"
  chmod +x "${topdir}/SOURCES/apple-docs"
  cat > "$spec" <<EOF
Name: apple-docs-test
Version: 1.0.0
Release: ${release}
Summary: Test package
License: MIT
BuildArch: x86_64

%description
Test package

%install
mkdir -p %{buildroot}/usr/bin
install -m 0755 %{_sourcedir}/apple-docs %{buildroot}/usr/bin/apple-docs

%files
/usr/bin/apple-docs
EOF
  rpmbuild --define "_topdir ${topdir}" --define "_tmppath ${topdir}/tmp" -bb "$spec" >/dev/null 2>&1
  cp "${topdir}/RPMS/x86_64/apple-docs-test-1.0.0-${release}.x86_64.rpm" "$out_file"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SOURCE_REPO="techprimate/apple-docs-cli"
CHANNEL=nightly PUBLISHER_TEST_MODE=1 source "${REPO_ROOT}/scripts/publish.sh"

[ "$SUITE" = "stable" ] || fail_test "legacy CHANNEL input must not enable nightly publishing"
[ "$PKG" = "apple-docs" ] || fail_test "manifest package name was not loaded"
[ "$BINARY_NAME" = "apple-docs" ] || fail_test "manifest binary name was not loaded"
[ "$PUBLISH_LINUX_PACKAGES" = "false" ] || fail_test "macOS-only project enabled Linux packages"
[ "${RELEASE_ASSETS[*]}" = "darwin-amd64 darwin-arm64" ] || fail_test "unexpected release assets"

if [ "${PUBLISHER_CONFIG_ONLY_TEST:-}" = "1" ]; then
  printf 'PASS: publisher configuration is stable-only\n'
  exit 0
fi

local_rpm="${WORK}/local.rpm"
remote_rpm="${WORK}/remote.rpm"
out_rpm="${WORK}/out.rpm"

build_test_rpm 1 "$local_rpm"
build_test_rpm 2 "$remote_rpm"

if cmp -s "$local_rpm" "$remote_rpm"; then
  fail_test "test setup expected RPM containers to differ"
fi

R2_BUCKET="test-bucket"
R2_S3_ENDPOINT="https://example.invalid"

s3api() {
  [ "$1" = "head-object" ] || fail_test "unexpected s3api command: $*"
}

s3() {
  [ "$1" = "cp" ] || fail_test "unexpected s3 command: $*"
  cp "$remote_rpm" "$3"
}

use_existing_rpm_if_same_content "$local_rpm" "apple-docs/rpm/stable/x86_64/apple-docs-test-1.0.0-1.x86_64.rpm" "$out_rpm"

cmp -s "$remote_rpm" "$out_rpm" || fail_test "expected existing remote RPM bytes to be reused"

printf 'PASS: matching RPM payloads reuse existing signed package bytes\n'
