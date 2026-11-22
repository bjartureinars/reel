# Reel — handoff notes for Claude Code

Personal project of Bjartur (Reykjavík). Two apps that turn his Mac mini into a private film service for
his Apple TV, built on Jellyfin, designed with the apple-design skill (Apple HIG):

- **Reel Server** (macOS, SwiftUI): runs and auto-configures a Jellyfin 12.4 server as a child process;
  drag-and-drop library; Bonjour advertising; Quick Connect pairing; menu bar extra; keeps Mac awake while streaming.
- **Reel** (tvOS, SwiftUI): Bonjour discovery → Quick Connect code pairing → Home / Films / Home Videos /
  Search / Settings → AVPlayerViewController playback with Jellyfin progress reporting.

Started in a claude.ai session on 2026-11-21; moved here 2026-11-22.

## Status (2026-11-22, after the Google Drive work)

- Project moved from the iCloud Desktop to `~/Reel` (`~/Desktop/Reel` is only a symlink).
- Google Drive storage built and installed on both the Mac and the Apple TV: drop folder `~/Reel/movies` →
  approve in Reel Server → upload → verify → delete original; on the TV: Stream or Download to Mac (one film at a time); live bitrate panel.
- Verified against a fake Drive: upload/verify/delete safety, and streaming the 4K remux through Jellyfin.
- Casino Royale verified in Drive and original removed 13:13; reads back from Drive at 254–325 Mbps.
- Skyfall incident 13:19–14:18, fixed the same afternoon with the approval gate (see Cloud design). Mac app installed.
  Skyfall's disc folder is back in the drop folder since 14:46, with his OK; its main clip is `BDMV/STREAM/00800.m2ts`, intact.
- **Not yet verified**: a real approval end to end, Download to Mac from real Drive (est. 21–27 min for 51 GB),
  Faster Uploads' read-back from real Drive, and playback and bitrate panel on the physical TV.

## Reel for iPhone (built 2026-11-22, installed on his iPhone 15, iOS 26.6)

- Bundle `com.bjartur.reel.phone`, target `ReelPhone`, iOS 18+, `bash ~/Reel/setup.sh iphone`. Streams the
  **original** straight from Google Drive (no Mac in the path); downloads Original, or Medium/Low copies the Mac makes.
- Sign-in: its own Google OAuth client "Reel iPhone" (iOS type, no secret) in `reel-515510`, created 2026-11-22
  with his OK. drive.file grants are per project: confirmed 2026-11-22 that the phone sees the films and
  details the Mac's Desktop client made.
- Engine (`Engine/ReelEngine.c`): FFmpeg 8.1.3 LGPL parts, static, built by `Tools/build-ffmpeg.sh` into
  `~/Developer/Reel/vendor/ffmpeg/<sdk>` (source tarball checked file by file against tag n8.1.3). Makes
  fMP4 HLS segments on the phone, served to AVPlayer from 127.0.0.1: picture copied untouched, AC3/E-AC3/AAC
  copied, DTS/DTS-HD/TrueHD/FLAC → ALAC (verified bit-exact), PGS/text subtitles drawn by the app.
  Segments start on keyframes from the MKV index or every 4 s; decode times are the segment's sorted pts
  minus a fixed delay, so any segment can be made alone after a seek and comes out identical.
  Keep the H.264/HEVC decoders: without them HDR colour tags are lost (tested). iOS has no MKV, M2TS or DTS.
- Mac side `Mac/Cloud/PhoneBridge.swift` (every 45 s): writes `reel=info` JSON per verified film (Jellyfin
  details + artwork, Blu-ray track languages from the disc's .clpi, cached in defaults); syncs `reel=watch`
  files ↔ Jellyfin UserData (`POST /UserItems/{id}/UserData`); makes `reel=copy` MKVs for `reel=request`s with
  Jellyfin's ffmpeg (VideoToolbox HEVC; hw decode only for HEVC sources, Blu-ray H.264 is faster in software).
  The phone lists only films that have an `info` file, so unverified or abandoned uploads never show.
  Protocol in `Shared/PhoneShared.swift`. Removing a film in Reel Server bins its iPhone files too.
- Downloads: background URLSession, 256 MB ranged pieces (fresh token per batch), MD5-checked against Drive.
- Verified in the simulator with his real films read locally (DEBUG-only `REEL_FILE_<id>` hook): 4K HDR10 play,
  resume, PGS subtitles, bitrate panel, Skyfall M2TS. Not yet verified: anything with real Drive on the phone,
  downloads, Medium/Low copies end to end, watch sync with the TV, PiP, AirPlay.

## Next steps

1. Skyfall cleanup is finished (2026-11-22: 49 clips in Drive's Bin, two local leftovers in the Mac's Trash).
   Skyfall is listed as waiting for approval, and he presses that button himself. Afterwards: confirm upload,
   verify, delete of only the main clip, and playback of the m2ts from Drive.
2. On the TV: Stream (check the panel says "Original 4K HEVC HDR10", no stalls), then Download to Mac → Play from Mac.
3. If AVPlayer rejects a DV stream, try removing the `DOVIWith*` range types from `DeviceProfile` in TV/Player.swift.

## Google Cloud (set up 2026-11-22)

- Project `reel-515510` (separate from his True Count Academy project: never touch that one). Drive API on,
  OAuth app External and **In production**. Publishing requires home page + privacy policy links, which are
  served by Firebase Hosting in the same project: https://reel-515510.web.app/ and /privacy (noindex).
  Don't delete that site; keep the policy true if what Reel does with Google data changes.

## Cloud design (don't undo these)

- `Mac/Cloud/`: NFSServer (read-only NFSv3 on loopback, mounted at `~/Library/Application Support/Reel/cloud-disk`
  with the built-in client), CloudDisk (routes reads to drop folder / download / Drive, RAM read-ahead),
  CloudStore (catalog, pipeline, offload), DriveClient + GoogleAuth (scope `drive.file`), ControlAPI (port 8097).
- It's a mounted disk and not .strm/HTTP because Jellyfin only throttles remuxes for File inputs.
- `EnableThrottling` + `EnableSegmentDeletion` must stay on: without them a remux fills the disk ("No space left").
- Jellyfin is launched with probesize 40M / analyzeduration 10M (default read 350 MB per start and seek).
- The TV gets its master playlist via `/v1/master`, which removes Jellyfin's tone-mapped H.264 SDR variant.
- `configureWhenReady` retries because Jellyfin 12's boot server answers "ready" before the real server is up.
- Faster Uploads (off by default): 8 URLSessions (one session = one TCP connection, varies 40–100 Mbit/s to Google;
  8 together measured a steady 105–128, which is the line's ceiling to Google; more lanes won't help.
  A Cloudflare test showing 250+ up didn't hold for Google. lsof doesn't list these sockets; use nettop) sending 1 GB pieces as separate Drive files (`RemoteFile`, `UploadPart`).
  A film is either `driveID` or a complete gap-free set of `parts`; always go through `film.remote`.
  Both methods' sessions are kept so the switch loses no progress.
- **Approval gate (2026-11-22, Bjartur's decision after an incident):** uTorrent saved a Blu-ray folder straight into
  the drop folder; Reel uploaded and deleted 46 clips (many unfinished) and Jellyfin titled them by number
  ("21 Jump Street", "UFC 259"). MD5 only proves Drive equals the file, not that the file was finished.
  So `DropInspector` only lists (`CloudStore.pending`, never in `films`); `approve()` from the Mac button is the
  only way in, and `approvedStamp == originalStamp` is checked before queueing, processing and deleting.
  Never auto-approve and don't expose approval on port 8097. BDMV = one film (largest clip by CLPI, exact size).
  `discarded.json` = abandoned upload ids that sync must never import as verified films.
- Bjartur chose automatic permanent deletion of originals after approval and verification. Never weaken the checks in
  `checkAndDeleteOriginal`; never test deletion with his real films.
- Backups from before this work: `~/Developer/Reel/backups/2026-11-22-pre-cloud*`.

## Build

```bash
bash ~/Reel/setup.sh        # Jellyfin + XcodeGen + Reel Server (installs to ~/Applications, opens it) + TV
bash ~/Reel/setup.sh mac    # Mac only
bash ~/Reel/setup.sh tv     # Apple TV only
```

- Source of truth: `~/Reel` (local only, not in iCloud; not a git repo; edit here).
  `setup.sh` rsyncs it to `~/Developer/Reel/src` and builds there, excluding `movies/`. Output log: `~/Reel/setup.log`.
- Project is generated by XcodeGen (`project.yml`, binary in `~/Developer/Reel/bin/xcodegen`). Don't hand-edit
  the .xcodeproj. Swift language mode 5 (SWIFT_VERSION 5.0), macOS 14+, tvOS 17+.
- Team `9U953J4FPN`. Mac target: manual signing, "Apple Development", no sandbox/hardened runtime.
  tvOS target: automatic signing; xcodebuild needs
  `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` (the second flag fixed "device isn't registered").
- Bundle IDs: `com.bjartur.reel.server`, `com.bjartur.reel.tv`.
- Machine: Mac mini (Apple silicon), macOS 27.2.1, Xcode 27.2, Swift 6.4.2, ~16 GB free plus whatever is in the drop folder (tight), Wi-Fi 192.168.1.79.

## Jellyfin 12 specifics

- Versioning jumped from 10.11 to 12.0 (Sept 2026). Installed: 12.4 arm64 dmg from repo.jellyfin.org
  (sha256 504c0e20…769d, pinned in setup.sh), copied to `~/Library/Application Support/Reel/Jellyfin.app`.
- Server data: `~/Library/Application Support/Reel/server`; libraries `~/Movies/Reel/Films` (movies) and
  `~/Movies/Reel/Home Videos` (homevideos). ~/Movies isn't iCloud-synced on purpose.
- Auth: `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…` header.
  Legacy auth (`api_key` query, X-Emby-*) is **disabled by default in 12.0**; media/image URLs use `ApiKey=`.
  `JellyfinClient.absolute()` rewrites any `api_key` in TranscodingUrl to `ApiKey`.
- Quick Connect: `POST /QuickConnect/Initiate` (GET is gone), poll `GET /QuickConnect/Connect?secret=`,
  then `POST /Users/AuthenticateWithQuickConnect`. Mac approves with `POST /QuickConnect/Authorize?code=&userId=`.
- Startup wizard endpoints are obsolete but still work; Reel Server uses them on first run, creating admin
  user = macOS short name with a random password stored in Keychain (service `com.bjartur.reel`).

## Code map

- `Shared/Jellyfin.swift` — client, models (PascalCase→camelCase decoder), image URLs, badges.
- `Shared/Keychain.swift` — Keychain + stable device ID.
- `Mac/ServerManager.swift` — process lifecycle, auto-setup, libraries, add (move/copy/link), Quick Connect,
  Bonjour (`_reel._tcp`, NetService), polling sessions/scan, keep-awake.
- `Mac/ReelServerApp.swift`, `ContentView.swift`, `AppleTVView.swift` — UI, menu bar, Settings, pairing sheet.
- `TV/ReelApp.swift` — app, AppSession (saved server, re-finds Mac by Bonjour name if its IP changes), tabs.
- `TV/ConnectView.swift` — NWBrowser discovery (IPv4 resolve), pairing view.
- `TV/BrowseViews.swift` — hero, shelves, cards (`.card` style), detail, grid, search, settings.
- `TV/Player.swift` — DeviceProfile (direct play MP4/MOV; else HLS fMP4 remux, video copy, EAC3 audio;
  SubtitleStreamIndex -1 to avoid burn-in), PlaybackController (AVPlayerViewController,
  appliesPreferredDisplayCriteriaAutomatically, progress/stop reports, ActiveEncodings cleanup).

## Design notes

Dark, backdrop-led tvOS UI; one brand color "projector gold" (#F5BA4A on TV; Mac accent light #A85F00 / dark
#F5BA4A, both ≥4.5:1). System player, system focus/card styles, title-case buttons, HIG copy. Icon: gold film
reel in projector light (layered tvOS imagestack + top shelf); generator script lived in the claude.ai sandbox only.

## Working with Bjartur

- Don't generate files (PDF/HTML etc.) unless he asks for a file.
- Confirm before moving/deleting his media; his Desktop/Documents are in iCloud.
