#!/bin/bash
# Step 2: fetch Jellyfin 12.4 (official build, checksum-verified) and XcodeGen; inspect the server bundle.
set -euo pipefail
SUP="$HOME/Library/Application Support/Reel"
mkdir -p "$SUP/downloads" "$HOME/Developer/Reel/bin"
DMG="$SUP/downloads/jellyfin_12.4-arm64.dmg"
URL="https://repo.jellyfin.org/files/server/macos/stable/v12.4/arm64/jellyfin_12.4-arm64.dmg"
SHA="504c0e201e4d9374403300622317b9a6b8b86f860a2a52eea5734f9abf70769d"
if ! echo "$SHA  $DMG" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "Downloading Jellyfin 12.4…"; curl -L --fail -sS -o "$DMG" "$URL"
fi
echo "$SHA  $DMG" | shasum -a 256 -c -
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
echo "== dmg contents"; ls -la "$MNT"
APP=$(find "$MNT" -maxdepth 1 -name "*.app" | head -1)
echo "== app: $APP"; plutil -p "$APP/Contents/Info.plist" | grep -E 'CFBundle(Identifier|ShortVersion|Executable)'
echo "== MacOS"; ls -la "$APP/Contents/MacOS"
echo "== Resources (top)"; ls "$APP/Contents/Resources" | head -40
echo "== Frameworks?"; ls "$APP/Contents/Frameworks" 2>/dev/null | head
find "$APP" -maxdepth 4 \( -name "jellyfin" -o -name "ffmpeg" -o -name "ffprobe" -o -name "jellyfin-web" -o -name "jellyfin.dll" \) | sed "s|$MNT||"
rm -rf "$SUP/Jellyfin.app"; ditto "$APP" "$SUP/Jellyfin.app"
hdiutil detach "$MNT" >/dev/null
xattr -dr com.apple.quarantine "$SUP/Jellyfin.app" 2>/dev/null || true
echo "Copied to $SUP/Jellyfin.app ($(du -sh "$SUP/Jellyfin.app" | cut -f1))"

echo "== XcodeGen"
if [ ! -x "$HOME/Developer/Reel/bin/xcodegen/bin/xcodegen" ]; then
  T=$(mktemp -d); curl -L --fail -sS -o "$T/xcodegen.zip" https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
  ditto -x -k "$T/xcodegen.zip" "$HOME/Developer/Reel/bin/"; xattr -dr com.apple.quarantine "$HOME/Developer/Reel/bin" 2>/dev/null || true
fi
"$HOME/Developer/Reel/bin/xcodegen/bin/xcodegen" --version
echo "== VLC Glass recents (to find your films)"
defaults read local.vlcglass.player recents.v1 2>/dev/null | xxd -r -p 2>/dev/null | python3 -c "import sys,json; [print(r['url']) for r in json.loads(sys.stdin.buffer.read())]" 2>/dev/null || python3 - <<'PY'
import plistlib, json, os, subprocess
p = os.path.expanduser("~/Library/Preferences/local.vlcglass.player.plist")
try:
    d = plistlib.load(open(p, "rb")); print("\n".join(r["url"] for r in json.loads(d["recents.v1"])))
except Exception as e: print("recents unavailable:", e)
PY
