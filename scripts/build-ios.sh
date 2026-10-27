#!/bin/zsh
set -eu

# Generates the Xcode project from iOS/project.yml (XcodeGen) and builds
# Mora for iPhone. Pass a simulator name to choose the destination.
MORA_PROJECT_DIR="${0:A:h:h}"
cd "$MORA_PROJECT_DIR/iOS"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
DESTINATION="platform=iOS Simulator,name=${1:-iPhone 17 Pro}"
xcodebuild -project MoraiOS.xcodeproj -scheme MoraiOS -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$MORA_PROJECT_DIR/.build/ios" build | tail -n 3
print "Готово: $MORA_PROJECT_DIR/.build/ios/Build/Products/Debug-iphonesimulator/Mora.app"
