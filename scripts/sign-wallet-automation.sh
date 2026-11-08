#!/bin/zsh
# Builds the Apple Pay automation from code, signs it and bundles it with the iPhone app.
# Run on a Mac with macOS 27 or later, signed in to the Mora service Apple ID:
# macOS 26 drops the automation trigger when signing, and the script refuses such a file.
set -eu

MORA_PROJECT_DIR="${0:A:h:h}"
cd "$MORA_PROJECT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 cloud/shortcuts/build_wallet_automation.py --output "$WORK/unsigned.shortcut" >/dev/null
shortcuts sign --mode anyone --input "$WORK/unsigned.shortcut" --output "$WORK/signed.shortcut"
python3 cloud/shortcuts/build_wallet_automation.py --verify "$WORK/signed.shortcut"
cp "$WORK/signed.shortcut" "iOS/Mora/Resources/Mora Apple Pay.shortcut"
# The Xcode project lists bundled files; without XcodeGen here, regenerate it on the development Mac.
if command -v xcodegen >/dev/null; then (cd iOS && xcodegen generate >/dev/null)
else print "XcodeGen не найден: выполните xcodegen generate в iOS/ на основном Mac или пришлите файл."; fi
print "Готово: iOS/Mora/Resources/Mora Apple Pay.shortcut"
