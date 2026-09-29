#!/bin/bash
# mac-setup.sh — run once on the rented Mac. Verifies Xcode and resolves packages.
set -euo pipefail

echo "==> Xcode version"
xcodebuild -version

echo "==> Accepting license (may need sudo password)"
sudo xcodebuild -license accept 2>/dev/null || true

echo "==> Resolving Swift packages (llama.swift — downloads the llama.cpp XCFramework)"
xcodebuild -resolvePackageDependencies -project Deck.xcodeproj -scheme Deck

echo "==> Listing targets (validates project.pbxproj parses)"
xcodebuild -list -project Deck.xcodeproj

echo "OK — ready to build. Next: ./scripts/build-ipa.sh <TEAM_ID> [BUNDLE_ID]"
