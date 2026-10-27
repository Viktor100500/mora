#!/bin/zsh
set -eu -o pipefail

# Builds Mora for iPhone (Release), installs it on a connected device and opens it.
# Signing uses DEVELOPMENT_TEAM from iOS/Local.xcconfig. Reinstalling keeps the
# app's data, so run it again when a free-team signature expires after 7 days.
#   zsh scripts/install-ios.sh ["device name, model or identifier"]
MORA_PROJECT_DIR="${0:A:h:h}"
OUTPUT="$MORA_PROJECT_DIR/.build/ios-device"
if ! grep -qE '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}' "$MORA_PROJECT_DIR/iOS/Local.xcconfig" 2>/dev/null; then
  print -u2 "Укажите команду разработчика в iOS/Local.xcconfig: DEVELOPMENT_TEAM = <Team ID>."
  print -u2 "Team ID есть в Xcode → Settings → Accounts → выбранная команда."
  exit 1
fi

mkdir -p "$OUTPUT"
xcrun devicectl list devices --json-output "$OUTPUT/devices.json" >/dev/null
SELECTION=$(python3 -I - "$OUTPUT/devices.json" "${1:-}" <<'EOF'
import json, sys

wanted = sys.argv[2].casefold()
phones = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
          if d.get("hardwareProperties", {}).get("platform") == "iOS"]

def name(device):
    return device.get("deviceProperties", {}).get("name", device["identifier"])

def ready(device):
    connection = device.get("connectionProperties", {})
    return connection.get("pairingState") == "paired" and connection.get("tunnelState") not in (None, "unavailable")

def matches(device):
    hardware = device.get("hardwareProperties", {})
    exact = {device["identifier"].casefold(), hardware.get("udid", "").casefold()}
    return wanted in exact or wanted in name(device).casefold() or wanted in hardware.get("marketingName", "").casefold()

candidates = [d for d in phones if matches(d)] if wanted else [d for d in phones if ready(d)]
if wanted and len(candidates) == 1 and not ready(candidates[0]):
    sys.exit(f"iPhone «{name(candidates[0])}» недоступен: подключите его кабелем, разблокируйте и нажмите «Доверять».")
if not candidates:
    sys.exit("Нет подключенного iPhone: подключите его кабелем, разблокируйте и нажмите «Доверять».")
if len(candidates) > 1:
    sys.exit("Подключено несколько iPhone, укажите нужный: " + ", ".join(f"«{name(d)}»" for d in candidates))
device = candidates[0]
print(device["identifier"], device["hardwareProperties"]["udid"], name(device), sep="\t")
EOF
)
IFS=$'\t' read -r DEVICE_ID DEVICE_UDID DEVICE_NAME <<< "$SELECTION"

cd "$MORA_PROJECT_DIR/iOS"
if command -v xcodegen >/dev/null; then xcodegen generate --quiet; fi
print "Сборка Mora для «$DEVICE_NAME»…"
if ! xcodebuild -project MoraiOS.xcodeproj -scheme MoraiOS -configuration Release \
  -destination "id=$DEVICE_UDID" -derivedDataPath "$OUTPUT" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$OUTPUT/build.log" 2>&1; then
  grep -E 'error:' "$OUTPUT/build.log" | sort -u | head -n 20 >&2 || true
  print -u2 "Сборка не удалась, журнал: $OUTPUT/build.log"
  exit 1
fi

APP="$OUTPUT/Build/Products/Release-iphoneos/Mora.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
print "Установка…"
if ! xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$OUTPUT/install.log" 2>&1; then
  cat "$OUTPUT/install.log" >&2
  exit 1
fi

if xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" > "$OUTPUT/launch.log" 2>&1; then
  print "Mora установлена и открыта на «$DEVICE_NAME»."
elif grep -qiE 'trusted|invalid code signature' "$OUTPUT/launch.log"; then
  print "Mora установлена. Чтобы ее открыть, разрешите разработчика на iPhone:"
  print "Настройки → Основные → VPN и управление устройством → Apple Development → Доверять."
else
  print "Mora установлена; откройте ее на iPhone. Журнал запуска: $OUTPUT/launch.log"
fi
EXPIRES=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)
if [[ -n "$EXPIRES" ]]; then
  print "Подпись действует до $(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$EXPIRES" '+%d.%m.%Y' 2>/dev/null || print -r -- "$EXPIRES"). Потом запустите эту команду снова: данные сохранятся."
fi
