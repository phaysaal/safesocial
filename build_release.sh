#!/bin/bash

# Spheres Automated Release Script
# Usage: ./build_release.sh <version>
# Example: ./build_release.sh 0.3.4
set -e

VERSION=${1:?Usage: ./build_release.sh <version>  e.g. 0.3.4}

echo "Starting Spheres v$VERSION release..."

# 1. Build Flutter APKs
echo "Building Flutter APKs..."
cd safesocial_app
export ANDROID_HOME=$HOME/Android/Sdk
flutter build apk --release --split-per-abi
cd ..

APK_DIR="safesocial_app/build/app/outputs/flutter-apk"

# 2. Create GitHub release and upload APKs
echo "Creating GitHub release v$VERSION..."
gh release create "$VERSION" \
  "$APK_DIR/app-arm64-v8a-release.apk" \
  "$APK_DIR/app-armeabi-v7a-release.apk" \
  "$APK_DIR/app-x86_64-release.apk" \
  --repo phaysaal/safesocial \
  --title "v$VERSION" \
  --generate-notes

# 3. Update landing page — replace every version string and download URL
echo "Updating landing page to v$VERSION..."
# Replace all vX.Y.Z occurrences (button captions, headings, paragraph text)
sed -i "s/v[0-9]\+\.[0-9]\+\.[0-9]\+/v${VERSION}/g" landing/index.html
# Replace the download URL version (releases/download/X.Y.Z/app...)
sed -i "s|releases/download/[0-9.]\+/app|releases/download/${VERSION}/app|g" landing/index.html

# 4. Deploy to Cloudflare Pages
echo "Deploying to Cloudflare Pages..."
npx wrangler pages deploy landing --project-name spheres-landing

# 5. Push landing page to gh-pages
echo "Pushing to gh-pages..."
git add landing/index.html
git commit -m "Update landing page to v$VERSION"
git worktree add /tmp/gh-pages-deploy origin/gh-pages
cp landing/index.html /tmp/gh-pages-deploy/index.html
cd /tmp/gh-pages-deploy
git add index.html
git commit -m "Update landing page to v$VERSION"
git push origin HEAD:gh-pages
cd -
git worktree remove /tmp/gh-pages-deploy --force

# 6. Push main
git push origin main

echo ""
echo "Release v$VERSION complete!"
echo "GitHub:     https://github.com/phaysaal/safesocial/releases/tag/$VERSION"
echo "Cloudflare: https://spheres-landing.pages.dev"
echo "Live site:  https://spheres.dev"
