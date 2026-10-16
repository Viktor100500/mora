#!/bin/zsh
set -eu

MORA_PROJECT_DIR="${0:A:h:h}"
cd "$MORA_PROJECT_DIR"
MORA_BUILD_ROOT="${MORA_BUILD_ROOT:-$MORA_PROJECT_DIR/build}"
export CLANG_MODULE_CACHE_PATH="$MORA_PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$MORA_PROJECT_DIR/.build/ModuleCache"

swift build -c release --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH"
mkdir -p "$MORA_BUILD_ROOT/Mora.app/Contents/MacOS" "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/MCP" "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/Prompts"
cp .build/release/Mora "$MORA_BUILD_ROOT/Mora.app/Contents/MacOS/Mora"
cp .build/release/MoraBridge "$MORA_BUILD_ROOT/Mora.app/Contents/MacOS/MoraBridge"
cp mcp/server.py mcp/requirements.txt mcp/README.md "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/MCP/"
cp Prompts/mora-csv.md Prompts/mora-mcp.md "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/Prompts/"
cp Resources/Info.plist "$MORA_BUILD_ROOT/Mora.app/Contents/Info.plist"
if [[ -f LICENSE ]]; then cp LICENSE "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/License.txt"; fi
ditto .build/release/Mora_FinanceCore.bundle "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/Mora_FinanceCore.bundle"
ditto Resources/en.lproj "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/en.lproj"
swift scripts/GenerateIcon.swift "$MORA_BUILD_ROOT/Mora.iconset"
cp "$MORA_BUILD_ROOT/AppIcon.icns" "$MORA_BUILD_ROOT/Mora.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$MORA_BUILD_ROOT/Mora.app/Contents/MacOS/MoraBridge"
codesign --force --sign - "$MORA_BUILD_ROOT/Mora.app"
codesign --verify --deep --strict "$MORA_BUILD_ROOT/Mora.app"
ditto -c -k --sequesterRsrc --keepParent "$MORA_BUILD_ROOT/Mora.app" "$MORA_BUILD_ROOT/Mora.zip"
print "Готово: $MORA_BUILD_ROOT/Mora.app"
