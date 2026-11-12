#!/bin/sh
# Generates the Xcode project and builds the app into build/.
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
xcodebuild -project AirPodKit.xcodeproj -scheme AirPodKit -configuration Debug \
  -derivedDataPath build -quiet build
echo "Built: $(pwd)/build/Build/Products/Debug/AirPod Kit.app"
