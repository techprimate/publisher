#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/release" "$WORK/bucket"

cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = "release download" ] || exit 2
shift 2
dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --pattern)
      if [ -f "$TEST_RELEASE/$2" ]; then
        mkdir -p "$dir"
        cp "$TEST_RELEASE/$2" "$dir/$2"
      fi
      shift 2 ;;
    *) shift ;;
  esac
done
EOF
cat > "$WORK/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = s3 ] || [ "$1" = s3api ] || exit 2
command="$1"
shift
[ "$1" = --endpoint-url ] || exit 2
shift 2
if [ "$command" = s3api ]; then
  [ "$1" = head-object ] || exit 2
  shift
  [ "$1" = --bucket ] || exit 2
  shift 2
  [ "$1" = --key ] || exit 2
  test -f "$TEST_BUCKET/$2"
else
  [ "$1" = cp ] || exit 2
  shift
  source="$1"
  target="$2"
  if [[ "$source" == s3://* ]]; then
    cp "$TEST_BUCKET/${source#s3://test-bucket/}" "$target"
  else
    mkdir -p "$(dirname "$TEST_BUCKET/${target#s3://test-bucket/}")"
    cp "$source" "$TEST_BUCKET/${target#s3://test-bucket/}"
  fi
fi
EOF
chmod +x "$WORK/bin/gh" "$WORK/bin/aws"
export PATH="$WORK/bin:$PATH" TEST_RELEASE="$WORK/release" TEST_BUCKET="$WORK/bucket"
export SOURCE_REPO=techprimate/AudioPatch TAG=v1.2.3
export R2_BUCKET=test-bucket R2_S3_ENDPOINT=https://example.invalid
export REGISTRY_DOMAIN=packages.techprimate.com

printf 'signed installer' > "$WORK/release/AudioPatch-HAL-Installer.pkg"
printf 'notarized app archive' > "$WORK/release/AudioPatch-HAL-Uninstaller.zip"
bash "$REPO_ROOT/scripts/publish.sh" > "$WORK/first.log"
key="$WORK/bucket/audiopatch/downloads/v1.2.3"
[ -f "$key/AudioPatch-HAL-Installer.pkg" ] || exit 1
[ -f "$key/AudioPatch-HAL-Uninstaller.zip" ] || exit 1

bash "$REPO_ROOT/scripts/publish.sh" > "$WORK/second.log"
printf 'changed installer' > "$WORK/release/AudioPatch-HAL-Installer.pkg"
if bash "$REPO_ROOT/scripts/publish.sh" > "$WORK/changed.log" 2>&1; then
  echo 'FAIL: changed published version was accepted' >&2
  exit 1
fi
grep -q 'immutability violation' "$WORK/changed.log"
[ "$(cat "$key/AudioPatch-HAL-Installer.pkg")" = 'signed installer' ] || exit 1

printf 'signed installer' > "$WORK/release/AudioPatch-HAL-Installer.pkg"
rm "$WORK/release/AudioPatch-HAL-Uninstaller.zip"
if bash "$REPO_ROOT/scripts/publish.sh" > "$WORK/missing.log" 2>&1; then
  echo 'FAIL: missing declared release asset was accepted' >&2
  exit 1
fi
grep -q 'missing release asset' "$WORK/missing.log"
printf 'PASS: declared downloads publish immutably and missing assets fail\n'
