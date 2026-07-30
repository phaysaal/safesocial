#!/bin/bash

# Spheres Automated Release Script
# Usage: ./build_release.sh <version>
# Example: ./build_release.sh 0.4.8
set -euo pipefail

VERSION=${1:?Usage: ./build_release.sh <version>  e.g. 0.4.8}

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: version must be X.Y.Z (got '$VERSION')" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ── Preflight ────────────────────────────────────────────────────────────────
# The script commits and pushes to main, so it must not sweep up unrelated work.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree is dirty. Commit or stash first —" >&2
  echo "this script commits landing/index.html and pushes to main." >&2
  git status --short >&2
  exit 1
fi

if [[ ! -f safesocial_app/android/key.properties ]]; then
  echo "Error: safesocial_app/android/key.properties is missing." >&2
  echo "Release builds require the signing keystore and will not fall back" >&2
  echo "to the public Android debug key." >&2
  exit 1
fi

if git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "Error: tag '$VERSION' already exists." >&2
  exit 1
fi

echo "Starting Spheres v$VERSION release..."

# ── 1. Bump the version everywhere it is recorded ────────────────────────────
# This has to happen BEFORE the build, or the APK carries the old versionName
# and versionCode while the release and website advertise the new one.
echo "Bumping version to $VERSION..."

CURRENT_BUILD=$(grep -m1 '^version:' safesocial_app/pubspec.yaml | sed 's/.*+//')
NEXT_BUILD=$((CURRENT_BUILD + 1))
sed -i "s/^version: .*/version: ${VERSION}+${NEXT_BUILD}/" safesocial_app/pubspec.yaml
sed -i "s/static const String version = '.*';/static const String version = '${VERSION}';/" \
  safesocial_app/lib/app_info.dart

echo "  pubspec.yaml  -> ${VERSION}+${NEXT_BUILD}"
echo "  app_info.dart -> ${VERSION}"

# ── 2. Build Flutter APKs ────────────────────────────────────────────────────
echo "Building Flutter APKs..."
pushd safesocial_app >/dev/null
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
flutter build apk --release --split-per-abi
popd >/dev/null

APK_DIR="safesocial_app/build/app/outputs/flutter-apk"

# ── Publish hashes ───────────────────────────────────────────────────────────
# Without these a user cannot check that a download matches what was built, and
# reproducing the build proves nothing because there is nothing to compare to.
echo "Recording build hashes..."
( cd "$APK_DIR" && sha256sum \
    app-arm64-v8a-release.apk \
    app-armeabi-v7a-release.apk \
    app-x86_64-release.apk ) > "$APK_DIR/SHA256SUMS.txt"
cat "$APK_DIR/SHA256SUMS.txt"

# ── 3. Update the landing page ───────────────────────────────────────────────
# Anchored to the Spheres version specifically, so unrelated version strings
# elsewhere on the page are not rewritten.
echo "Updating landing page to v$VERSION..."
sed -i "s/Spheres v[0-9]\+\.[0-9]\+\.[0-9]\+/Spheres v${VERSION}/g" landing/index.html
sed -i "s|releases/download/[0-9.]\+/app|releases/download/${VERSION}/app|g" landing/index.html

# ── 4. Commit the version bump and landing page ──────────────────────────────
echo "Committing version bump..."
git add safesocial_app/pubspec.yaml safesocial_app/lib/app_info.dart landing/index.html
git commit -m "Release v$VERSION"

# ── 5. Publish the GitHub release ────────────────────────────────────────────
echo "Creating GitHub release v$VERSION..."
gh release create "$VERSION" \
  "$APK_DIR/app-arm64-v8a-release.apk" \
  "$APK_DIR/app-armeabi-v7a-release.apk" \
  "$APK_DIR/app-x86_64-release.apk" \
  "$APK_DIR/SHA256SUMS.txt" \
  --repo phaysaal/safesocial \
  --title "v$VERSION" \
  --notes "$(cat <<NOTES
Built with the toolchain pinned in \`FLUTTER_TOOLCHAIN\`.

To check a download, or to rebuild this release yourself and compare:

\`\`\`
scripts/verify_build.sh $VERSION
\`\`\`

\`\`\`
$(cat "$APK_DIR/SHA256SUMS.txt")
\`\`\`
NOTES
)"

# ── 6. Deploy the site ───────────────────────────────────────────────────────
echo "Deploying to Cloudflare Pages..."
npx wrangler pages deploy landing --project-name spheres-landing

echo "Pushing to gh-pages..."
WORKTREE=$(mktemp -d -t gh-pages-deploy-XXXXXX)
rm -rf "$WORKTREE"
git fetch origin gh-pages
git worktree add "$WORKTREE" origin/gh-pages
cp landing/index.html "$WORKTREE/index.html"
git -C "$WORKTREE" add index.html
git -C "$WORKTREE" commit -m "Update landing page to v$VERSION"
git -C "$WORKTREE" push origin HEAD:gh-pages
git worktree remove "$WORKTREE" --force

# ── 7. Push main ─────────────────────────────────────────────────────────────
git push origin main

echo ""
echo "Release v$VERSION complete!"
echo "GitHub:     https://github.com/phaysaal/safesocial/releases/tag/$VERSION"
echo "Cloudflare: https://spheres-landing.pages.dev"
echo "Live site:  https://spheres.dev"
