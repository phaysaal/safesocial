#!/bin/bash

# Spheres v0.3.0 Automated Build Script
set -e

echo "🚀 Starting Spheres v0.3.0 Release Build..."

# 1. Build Rust Core (Standard Release)
echo "🦀 Building Rust Core..."
cd safesocial_core
cargo build --release
cd ..

# 2. Prepare Flutter
echo "🐦 Building Flutter APK..."
cd safesocial_app
# Ensure Android SDK is found (Environment specific)
export ANDROID_HOME=$HOME/Android/Sdk
flutter build apk --release --split-per-abi
cd ..

echo "✨ Build Complete!"
echo "📦 APKs available in: safesocial_app/build/app/outputs/flutter-apk/"
echo "🔗 Next steps: Upload to GitHub and run 'gh release create 0.3.0'"
