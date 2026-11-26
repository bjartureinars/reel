#!/bin/bash
# Reel setup: installs the Jellyfin server, builds Reel Server for this Mac, and builds and installs
# Reel on a paired Apple TV.
#
#   bash ~/Reel/setup.sh        everything
#   bash ~/Reel/setup.sh mac    only the Mac app (and Jellyfin)
#   bash ~/Reel/setup.sh tv     only the Apple TV app
#   bash ~/Reel/setup.sh iphone only the iPhone and iPad app (every connected iPhone and iPad)
#   bash ~/Reel/setup.sh ipad   the same
#
# Progress is also written to setup.log next to this script.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/Developer/Reel"            # outside iCloud: builds there don't sync or get evicted
SUPPORT="$HOME/Library/Application Support/Reel"
MODE="${1:-all}"
[[ "$MODE" == "ipad" ]] && MODE="iphone"     # one app runs on both
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
rsync -a --delete --exclude setup.log --exclude '/movies' --exclude '/tv shows' --exclude '/extras' --exclude '/.claude' --exclude '*.xcodeproj' "$SRC/" "$WORK/src/"

if [[ "$MODE" != "tv" && "$MODE" != "iphone" ]]; then
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

if [[ "$MODE" == "all" || "$MODE" == "mac" ]]; then
    if [[ ! -x "$WORK/vendor/reel-torrent/reel-torrent" || "$WORK/src/Tools/reel-torrent/main.cpp" -nt "$WORK/vendor/reel-torrent/reel-torrent" ]]; then
        step "Building the torrent helper (libtorrent)"
        bash "$WORK/src/Tools/build-torrent.sh" || fail "The torrent helper didn't build."
    fi
    step "Building Reel Server for this Mac"
    xcodebuild -project Reel.xcodeproj -scheme ReelServer -configuration Release \
        -derivedDataPath "$WORK/build" -quiet build \
        || fail "Reel Server didn't build. The errors are above."
    BUILT="$WORK/build/Build/Products/Release/Reel Server.app"
    osascript -e 'tell application "Reel Server" to quit' >/dev/null 2>&1 || true
    # An open window can refuse that quit; then the old app would keep running with its server stopped.
    APP_BIN="$HOME/Applications/Reel Server.app/Contents/MacOS/Reel Server"
    for _ in $(seq 1 10); do pgrep -U "$(id -u)" -f "$APP_BIN" >/dev/null || break; sleep 1; done
    pkill -TERM -U "$(id -u)" -f "$APP_BIN" 2>/dev/null || true
    for _ in $(seq 1 10); do pgrep -U "$(id -u)" -f "$APP_BIN" >/dev/null || break; sleep 1; done
    pkill -KILL -U "$(id -u)" -f "$APP_BIN" 2>/dev/null || true
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

if [[ "$MODE" == "all" || "$MODE" == "iphone" ]]; then
    step "Building the iPhone engine (FFmpeg, LGPL parts only)"
    if [[ ! -f "$WORK/vendor/ffmpeg/iphoneos/lib/libavformat.a" ]]; then
        [[ -f "$WORK/vendor/ffmpeg-8.1.3-download/ffmpeg-8.1.3.tar.xz" ]] || fail "The FFmpeg source isn't in $WORK/vendor. Ask Claude to fetch it again."
        bash "$WORK/src/Tools/build-ffmpeg.sh" || fail "The iPhone engine didn't build."
    else
        echo "Already built."
    fi

    step "Looking for your iPhone and iPad"
    PJSON=$(mktemp)
    xcrun devicectl list devices --json-output "$PJSON" >/dev/null 2>&1 || true
    PHONE=$(python3 - "$PJSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and hw.get("reality") == "physical" and hw.get("deviceType") in ("iPhone", "iPad") \
            and d.get("connectionProperties", {}).get("pairingState") == "paired":
        print((hw.get("udid") or d.get("identifier")) + " " + hw.get("deviceType"))
PY
)
    [[ -n "$PHONE" ]] || fail "No paired iPhone or iPad. Connect it with a cable, unlock it, tap Trust, then run: bash ~/Reel/setup.sh iphone"

    while read -r DEVICE KIND; do
        # Building for each device registers it with Apple, so the app is allowed to run on it.
        step "Building Reel for your $KIND"
        xcodebuild -project Reel.xcodeproj -scheme ReelPhone -configuration Release \
            -destination "id=$DEVICE" -derivedDataPath "$WORK/build" \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build \
            || fail "Reel for $KIND didn't build. The errors are above."

        step "Installing on your $KIND"
        xcrun devicectl device install app --device "$DEVICE" "$WORK/build/Build/Products/Release-iphoneos/Reel.app" \
            || fail "Install failed. Unlock the $KIND, keep it connected, then run: bash ~/Reel/setup.sh iphone"
        xcrun devicectl device process launch --device "$DEVICE" com.bjartur.reel.phone >/dev/null 2>&1 || true
        echo "Reel is installed on your $KIND. If it says Untrusted Developer: Settings → General → VPN & Device Management."
    done <<< "$PHONE"
fi

if [[ "$MODE" == "all" || "$MODE" == "tv" ]]; then
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

    if [[ ! -f "$WORK/vendor/ffmpeg/appletvos/lib/libavformat.a" ]]; then
        step "Building the Apple TV engine (FFmpeg, LGPL parts only)"
        [[ -f "$WORK/vendor/ffmpeg-8.1.3-download/ffmpeg-8.1.3.tar.xz" ]] || fail "The FFmpeg source isn't in $WORK/vendor. Ask Claude to fetch it again."
        bash "$WORK/src/Tools/build-ffmpeg.sh" appletvos appletvsimulator || fail "The Apple TV engine didn't build."
    fi

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
