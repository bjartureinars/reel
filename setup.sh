#!/bin/bash
# Reel setup: installs the Jellyfin server, builds Reel Server for this Mac, and builds and installs
# Reel on a paired Apple TV.
#
#   bash ~/Reel/setup.sh        everything
#   bash ~/Reel/setup.sh mac    only the Mac app (and Jellyfin)
#   bash ~/Reel/setup.sh tv     only the Apple TV app
#
# Progress is also written to setup.log next to this script.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/Developer/Reel"            # outside iCloud: builds there don't sync or get evicted
SUPPORT="$HOME/Library/Application Support/Reel"
MODE="${1:-all}"
exec > >(tee "$SRC/setup.log") 2>&1

JELLYFIN_VERSION="12.4"
JELLYFIN_URL="https://repo.jellyfin.org/files/server/macos/stable/v12.4/arm64/jellyfin_12.4-arm64.dmg"
JELLYFIN_SHA256="504c0e201e4d9374403300622317b9a6b8b86f860a2a52eea5734f9abf70769d"

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$1"; echo "SETUP-RESULT=failed"; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail "This script downloads the Apple silicon build of Jellyfin."
xcodebuild -version >/dev/null 2>&1 || fail "Xcode isn't ready. Open Xcode once, accept the license, then run this again."

step "Copying the project to $WORK"
mkdir -p "$WORK/src" "$WORK/bin"
rsync -a --delete --exclude setup.log --exclude '/movies' --exclude '*.xcodeproj' "$SRC/" "$WORK/src/"

if [[ "$MODE" != "tv" ]]; then
    step "Jellyfin $JELLYFIN_VERSION (official build from jellyfin.org)"
    mkdir -p "$SUPPORT/downloads"
    DMG="$SUPPORT/downloads/jellyfin_${JELLYFIN_VERSION}-arm64.dmg"
    INSTALLED=$(defaults read "$SUPPORT/Jellyfin.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
    if [[ "$INSTALLED" == "$JELLYFIN_VERSION"* ]]; then
        echo "Already installed ($INSTALLED)."
    else
        if ! echo "$JELLYFIN_SHA256  $DMG" | shasum -a 256 -c - >/dev/null 2>&1; then
            curl -L --fail --progress-bar -o "$DMG" "$JELLYFIN_URL"
        fi
        echo "$JELLYFIN_SHA256  $DMG" | shasum -a 256 -c - || fail "Jellyfin download failed its checksum. Delete $DMG and retry."
        MNT=$(mktemp -d)
        hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
        APP=$(find "$MNT" -maxdepth 1 -name "*.app" | head -1)
        [[ -n "$APP" ]] || { hdiutil detach "$MNT" >/dev/null; fail "No app found inside the Jellyfin download."; }
        # Stop a running copy before replacing it.
        pkill -f "$SUPPORT/Jellyfin.app" 2>/dev/null || true
        rm -rf "$SUPPORT/Jellyfin.app"
        ditto "$APP" "$SUPPORT/Jellyfin.app"
        hdiutil detach "$MNT" >/dev/null
        echo "Installed: $(defaults read "$SUPPORT/Jellyfin.app/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
        echo "Server binary: $(find "$SUPPORT/Jellyfin.app" -name jellyfin -type f -perm +111 | head -1)"
    fi
fi

step "XcodeGen (generates the Xcode project)"
XCODEGEN="$WORK/bin/xcodegen/bin/xcodegen"
if [[ ! -x "$XCODEGEN" ]]; then
    T=$(mktemp -d)
    curl -L --fail -sS -o "$T/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
    ditto -x -k "$T/xcodegen.zip" "$WORK/bin/"
fi
"$XCODEGEN" --version
cd "$WORK/src"
"$XCODEGEN" generate --quiet
echo "Generated Reel.xcodeproj"

if [[ "$MODE" != "tv" ]]; then
    step "Building Reel Server for this Mac"
    xcodebuild -project Reel.xcodeproj -scheme ReelServer -configuration Release \
        -derivedDataPath "$WORK/build" -quiet build \
        || fail "Reel Server didn't build. The errors are above."
    BUILT="$WORK/build/Build/Products/Release/Reel Server.app"
    osascript -e 'tell application "Reel Server" to quit' >/dev/null 2>&1 || true
    # A new Reel Server would adopt a Jellyfin left over from the old one (and miss its new settings),
    # so end that one server, matched by this user and Reel's own data folder, and wait for it to go.
    REEL_JELLYFIN="$SUPPORT/Jellyfin.app/Contents/MacOS/jellyfin --datadir $SUPPORT/server"
    pkill -TERM -U "$(id -u)" -f "$REEL_JELLYFIN" || true
    for _ in $(seq 1 30); do
        pgrep -U "$(id -u)" -f "$REEL_JELLYFIN" >/dev/null || break
        sleep 1
    done
    sleep 1
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Reel Server.app"
    ditto "$BUILT" "$HOME/Applications/Reel Server.app"
    echo "Installed to ~/Applications/Reel Server.app"
    open "$HOME/Applications/Reel Server.app"
fi

if [[ "$MODE" != "mac" ]]; then
    step "Looking for a paired Apple TV"
    JSON=$(mktemp)
    xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
    UDID=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "tvOS" and hw.get("reality") == "physical" \
            and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print(hw.get("udid") or d.get("identifier")); break
PY
)
    if [[ -z "$UDID" ]]; then
        cat <<'MSG'
No paired Apple TV yet. One-time pairing:
  1. On the Apple TV: Settings → Remotes and Devices → Remote App and Devices. Leave that screen open.
  2. On this Mac: open Xcode → Window → Devices and Simulators. Your Apple TV appears on the left.
  3. Click it, click Pair, and type the code shown on the TV.
  4. Run:  bash ~/Reel/setup.sh tv
MSG
        echo "SETUP-RESULT=needs-apple-tv-pairing"
        exit 0
    fi
    NAME=$(python3 -c "import json,sys; d=[x for x in json.load(open('$JSON'))['result']['devices'] if (x.get('hardwareProperties',{}).get('udid') or x.get('identifier'))=='$UDID'][0]; print(d['deviceProperties']['name'])" 2>/dev/null || echo "Apple TV")
    echo "Found: $NAME ($UDID)"

    step "Building Reel for Apple TV"
    xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Release \
        -destination "id=$UDID" -derivedDataPath "$WORK/build" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build \
        || fail "Reel for Apple TV didn't build. If the error mentions signing or registering, open Xcode → Settings → Accounts, select your Apple ID, check that team 9U953J4FPN is listed, then run: bash ~/Reel/setup.sh tv"

    step "Installing on $NAME"
    TVAPP="$WORK/build/Build/Products/Release-appletvos/Reel.app"
    xcrun devicectl device install app --device "$UDID" "$TVAPP" || fail "Install failed. Keep the Apple TV awake and on the same network, then run: bash ~/Reel/setup.sh tv"
    xcrun devicectl device process launch --device "$UDID" com.bjartur.reel.tv >/dev/null 2>&1 || true
    echo "Reel is installed on $NAME and opening now."
fi

echo "SETUP-RESULT=ok"
