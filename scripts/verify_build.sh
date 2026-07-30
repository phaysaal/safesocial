#!/bin/bash
#
# Rebuild a published release and compare it against the hashes that release
# published. Anyone can run this; it needs no keys and no access to anything.
#
#   scripts/verify_build.sh 0.4.8
#
# A match means the published APK was built from this source with this
# toolchain. A mismatch means it was not — which is worth investigating before
# assuming a bug in this script.
set -euo pipefail

VERSION=${1:?Usage: scripts/verify_build.sh <version>}
REPO=${REPO:-phaysaal/safesocial}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# ── Toolchain ────────────────────────────────────────────────────────────────
# Different versions produce different bytes, so a mismatch here explains a
# mismatch later and is worth catching first.
expected_flutter=$(grep '^flutter=' FLUTTER_TOOLCHAIN | cut -d= -f2)
actual_flutter=$(flutter --version 2>/dev/null | head -1 | awk '{print $2}')

if [[ "$expected_flutter" != "$actual_flutter" ]]; then
  echo "Toolchain mismatch." >&2
  echo "  expected Flutter $expected_flutter, found ${actual_flutter:-none}" >&2
  echo "  see FLUTTER_TOOLCHAIN for every pinned version" >&2
  exit 1
fi

WORKDIR=$(mktemp -d -t spheres-verify-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "Fetching published hashes for v$VERSION..."
gh release download "$VERSION" --repo "$REPO" --pattern 'SHA256SUMS.txt' \
  --dir "$WORKDIR" || {
    echo "No SHA256SUMS.txt in that release — it predates hash publication." >&2
    exit 1
  }

echo "Checking out v$VERSION..."
git fetch --tags --quiet
git -c advice.detachedHead=false checkout --quiet "$VERSION"

echo "Building (this takes a while)..."
pushd safesocial_app >/dev/null
flutter clean >/dev/null
flutter pub get >/dev/null
# Unsigned: signing needs a keystore only the maintainer has, and the signature
# is not part of what is being verified here.
flutter build apk --release --split-per-abi
popd >/dev/null

APK_DIR="safesocial_app/build/app/outputs/flutter-apk"

echo
echo "Published vs rebuilt:"
status=0
while read -r expected name; do
  [[ -z "$name" ]] && continue
  if [[ ! -f "$APK_DIR/$name" ]]; then
    echo "  MISSING  $name"
    status=1
    continue
  fi
  actual=$(sha256sum "$APK_DIR/$name" | cut -d' ' -f1)
  if [[ "$actual" == "$expected" ]]; then
    echo "  MATCH    $name"
  else
    echo "  DIFFERS  $name"
    echo "           published $expected"
    echo "           rebuilt   $actual"
    status=1
  fi
done < "$WORKDIR/SHA256SUMS.txt"

echo
if [[ $status -eq 0 ]]; then
  echo "Verified: the published build matches this source."
else
  echo "Not verified. See docs/reproducible_builds.md for the known causes,"
  echo "including the ones that are expected today."
fi
exit $status
