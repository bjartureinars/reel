# Reel: the whole application, explained

A briefing for another Claude session. It explains what Reel is, how the pieces fit together, and which
decisions must not be undone. Written 2026-11-22. `CLAUDE.md` in the same folder holds the shorter working
notes and the current status. Read both before you change anything.

---

## 1. What Reel is

Reel is Bjartur's private film service (he lives in Reykjavík). His Mac mini holds and serves his films,
Google Drive stores them, and he watches on his Apple TV and iPhone. It's a personal project, not for sale.
He decides; you build and explain in plain language.

There are three apps and one shared engine:

| App | Platform | Bundle ID | Role |
|---|---|---|---|
| **Reel Server** | macOS 14+ (SwiftUI) | `com.bjartur.reel.server` | Runs Jellyfin 12.4, manages the library, uploads to Google Drive, serves the Apple TV, bridges data to the iPhone |
| **Reel** (TV) | tvOS 17+ (SwiftUI) | `com.bjartur.reel.tv` | Browses and plays films from the Mac, which reads them from the drop folder or Drive |
| **Reel for iPhone and iPad** | iOS/iPadOS 18+ (SwiftUI, one universal app) | `com.bjartur.reel.phone` | Streams originals **straight from Google Drive** (no Mac involved); offline downloads |
| **ReelEngine** | C, inside the iPhone app | — | FFmpeg-based remuxer that turns MKV/M2TS into HLS that AVPlayer can play |

The design follows Apple's Human Interface Guidelines through the `apple-design` skill
(`.claude/skills/apple-design`). The look is dark and led by backdrops, with one brand colour, "projector
gold", `#F5BA4A` (Mac accent in light mode: `#A85F00`). Everything else uses system controls, system focus
and card styles, title-case buttons and HIG wording.

---

## 2. The big picture

```
                      ┌──────────────────── Google Drive (scope drive.file) ────────────────────┐
                      │  films (whole file or 1 GB parts) + reel=info / copy / request / watch   │
                      └───────▲───────────────────────────────▲───────────────────────▲──────────┘
                upload/verify │                     read-back │                stream │ download
                              │                               │                       │
 ~/Reel/movies ──approve──► Reel Server (Mac mini) ──────────────────────┐       Reel for iPhone
 (drop folder)              │ CloudStore pipeline                         │       (ReelEngine → local HLS
                            │ NFSServer: loopback read-only disk ◄─ CloudDisk routes reads:   → AVPlayer)
                            │      ▲                                drop folder / download / Drive
                            │      │ File input
                            │   Jellyfin 12.4 (child process, port 8096)
                            │ ControlAPI (port 8097)   Bonjour _reel._tcp   PhoneBridge (every 45 s)
                            └──────────────┬──────────────────────────────
                                           │ LAN
                                      Apple TV app
```

---

## 3. Reel Server (macOS) in detail

### 3.1 Jellyfin hosting (`Mac/ServerManager.swift`)
- Jellyfin 12.4 arm64 is installed by `setup.sh` from repo.jellyfin.org (sha256 pinned) and copied to
  `~/Library/Application Support/Reel/Jellyfin.app`. Server data lives in `…/Reel/server`.
- It runs as a **child process**. On first run Reel Server goes through the (obsolete but working) startup
  wizard endpoints and creates an admin user named after the macOS short name. The random password goes in
  Keychain under service `com.bjartur.reel`. **Never read Keychain secrets or tokens.**
- The libraries are `~/Movies/Reel/Films` (movies) and `~/Movies/Reel/Home Videos` (homevideos).
- Jellyfin is launched with probesize 40M / analyzeduration 10M. The default would read about 350 MB on
  every start and seek.
- `configureWhenReady` retries, because Jellyfin 12's boot server answers "ready" before the real server is up.
- Other duties:
  - Bonjour advertising as `_reel._tcp` (NetService).
  - Quick Connect approval for pairing the TV.
  - Polling sessions and scans.
  - Keeping the Mac awake while something is streaming.
  - A menu bar extra.
  - Drag-and-drop adding of films (move, copy or link).

**Jellyfin 12 differences that matter:**
- Legacy auth (`api_key` query, `X-Emby-*`) is **disabled by default**. Use the header
  `Authorization: MediaBrowser Client=…, Device=…, DeviceId=…, Version=…, Token=…`, and `ApiKey=` in media and
  image URLs. `JellyfinClient.absolute()` rewrites `api_key` → `ApiKey` in TranscodingUrl.
- Quick Connect:
  - The TV starts with `POST /QuickConnect/Initiate` (GET is gone), then polls `GET /QuickConnect/Connect?secret=`, then calls `POST /Users/AuthenticateWithQuickConnect`.
  - The Mac approves with `POST /QuickConnect/Authorize?code=&userId=`.

### 3.2 Cloud storage (`Mac/Cloud/`)

| File | What it does |
|---|---|
| `GoogleAuth.swift` | OAuth (Desktop client), scope `drive.file` only |
| `DriveClient.swift` | Drive REST: upload, ranged read, list, create, update, replace, contents, appProperties |
| `RemoteFile.swift` | A film in Drive: either one `driveID` or a complete, gap-free set of 1 GB `parts`. Always go through `film.remote` |
| `CloudFiles.swift` | File identity stamps (size + dates + inode; symlinks never followed), MD5 of the whole file and of each piece, real free space, a check for "still being written" |
| `DropInspector.swift` | Watches the drop folder `~/Reel/movies` and only **lists** what it finds (in `CloudStore.pending`). A BDMV folder counts as one film: the largest clip by CLPI, exact size |
| `CloudStore.swift` | Catalog, upload → verify → delete pipeline, offload, the `discarded.json` list of abandoned uploads |
| `NFSServer.swift` | A read-only NFSv3 server on loopback, mounted with macOS's built-in client at `~/Library/Application Support/Reel/cloud-disk` |
| `CloudDisk.swift` | Answers that disk's reads from the drop folder, a local download, or Drive, with RAM read-ahead |
| `ControlAPI.swift` + `MiniHTTP.swift` | Port 8097 API for the TV. It accepts any token Jellyfin accepts, so there's no second pairing |
| `PhoneBridge.swift` | Publishes data to Drive for the iPhone (see §5.5) |

**Why a mounted disk and not .strm/HTTP:** Jellyfin only throttles remuxes for *File* inputs. Without
throttling, a remux fills the disk. `EnableThrottling` and `EnableSegmentDeletion` must stay on ("No space left").

**The pipeline:**
1. A file appears in the drop folder and DropInspector lists it as pending.
2. Bjartur presses **Approve** in Reel Server.
3. The file uploads and Drive's MD5 is checked against the local MD5.
4. `checkAndDeleteOriginal` **permanently deletes the original**, which is Bjartur's explicit choice.
5. The film is then read from Drive through the NFS disk.

**Faster Uploads** (off by default) uses 8 URLSessions (one TCP connection each) sending 1 GB parts as
separate Drive files. That gives 105–128 Mbit/s, which is the line's ceiling to Google; more lanes don't help.
Both upload methods keep their sessions, so switching between them loses no progress. `lsof` doesn't show
these sockets; use `nettop`.

### 3.3 The approval gate: DO NOT WEAKEN
On 2026-11-22, uTorrent saved a half-finished Blu-ray folder into the drop folder. Reel uploaded and deleted
46 clips, many of them unfinished, and Jellyfin gave them nonsense titles. MD5 proves Drive equals the file,
not that the file was *finished*. Since then:
- `DropInspector` only lists. Nothing enters `films` without `approve()`, which is called **only from the
  Mac UI button**.
- `approvedStamp == originalStamp` is checked again before queueing, processing and deleting.
- Never auto-approve. Never expose approval on port 8097 or anywhere else.
- Never weaken `checkAndDeleteOriginal`. Never test deletion with his real films.
- `discarded.json` holds abandoned upload IDs that a sync must never import as verified films.

### 3.3b TV shows
`~/Reel/tv shows` is the second drop folder (show folder, seasons inside). Episodes go through the same approval,
upload, check and delete as films, and appear on the cloud disk as `TV Shows/<Show>/Season NN/`, read by Jellyfin's
TV Shows library. Apple TV and iPhone/iPad have TV Shows tabs, show pages with seasons and episodes, Next Up, and
play the next episode automatically. See CLAUDE.md "TV shows".

### 3.4 Film management (`Mac/FilmManagement.swift`)
Reel is films only; Home Videos was removed on 2026-11-23. Clicking a film in Reel Server opens its window:
- **Identify Film:** searches Jellyfin's film databases, both with and without the year, and applies the
  chosen film (title, details, poster, backdrop).
- **Change Poster / Change Backdrop:** pick from the databases, or use your own picture (Choose File or drag
  it in). A new backdrop replaces the old ones.
- **Delete from Google Drive:** sends the film to Drive's Bin, where it stays restorable for 30 days.
Right-clicking a film offers the same actions. Changes reach the TV at once, and the iPhone within about a
minute (PhoneBridge republishes when image tags change).

### 3.5 Mac UI
- `ReelServerApp.swift`: app, menu bar extra, Settings.
- `ContentView.swift`: library and drop zone.
- `CloudView.swift`: Drive status, the pending list with Approve, and the PhoneBox (iPhone status).
- `AppleTVView.swift`: pairing sheet.

---

## 4. Reel for Apple TV

| File | What it does |
|---|---|
| `TV/ReelApp.swift` | App, `AppSession` (saved server; finds the Mac again by its Bonjour name if its IP changes), tabs: Home / Films / Search / Settings |
| `TV/ConnectView.swift` | NWBrowser discovery (resolves to IPv4), Quick Connect code pairing |
| `TV/BrowseViews.swift` | Hero, shelves, cards (`.card` style), detail, grid, search, settings |
| `TV/FilmActions.swift` | Detail page controls. A Drive film offers **Stream** and **Download to Mac** (one film at a time); local films just play |
| `TV/CloudClient.swift` | Talks to ControlAPI on 8097 |
| `TV/Player.swift` | `DeviceProfile`: direct-play MP4/MOV, otherwise HLS fMP4 remux with the video copied and EAC3 audio; `SubtitleStreamIndex -1` so subtitles are never burned in. `PlaybackController` (AVPlayerViewController, `appliesPreferredDisplayCriteriaAutomatically`, progress/stop reports, ActiveEncodings cleanup) |
| `TV/BitrateOverlay.swift` | Live bitrate panel over the player, toggled from the transport bar |

The TV gets its master playlist from `/v1/master` on port 8097. That playlist leaves out Jellyfin's
tone-mapped H.264 SDR variant, which AVPlayer otherwise sometimes picks, turning a 4K HDR remux into a live
re-encode. If Reel Server doesn't answer, the TV falls back to Jellyfin's own playlist. If AVPlayer ever
rejects a Dolby Vision stream, try removing the `DOVIWith*` range types from `DeviceProfile`.

---

## 5. Reel for iPhone

What Bjartur asked for:
- Everything the TV app does, and more.
- Streaming **only from Google's servers, only in full original quality**.
- Offline downloads like Netflix, as Original, or Custom (Original / Medium / Low).

### 5.1 Screens (`Phone/Screens.swift`, `FilmDetailView.swift`, `Components.swift`, `PlayerView.swift`)
- **Tabs:** Sign in (Google), Home (hero, Continue Watching, shelves), Films (sort and genre filter), Search,
  Downloads.
- **Detail page:** Play/Resume, Download with a quality choice, track languages, badges (4K, HDR10, DV, Atmos…).
- **Player:** custom controls on AVPlayer, subtitle and audio menus, bitrate panel, PiP and AirPlay (not yet
  tested on the device).

### 5.2 Sign-in (`Phone/GoogleAccount.swift`)
- Uses its own OAuth client "Reel iPhone" (iOS type, PKCE, no secret) in Google Cloud project `reel-515510`.
- `drive.file` grants are per *project*, so the phone sees the files the Mac's Desktop client created. This
  was confirmed on 2026-11-22.

### 5.3 Library (`Phone/Library.swift`)
- Reads Drive files tagged with appProperties `reel=…`.
- Lists **only films that have a `reel=info` file**, which the Mac writes after verification. Unverified or
  abandoned uploads therefore never appear.
- Caches everything, including artwork, on the phone so it works offline.

### 5.4 Playback path (`FilmReader.swift`, `Engine.swift`, `Player.swift`, `Engine/ReelEngine.c`)
1. **`DriveReader`** reads bytes straight from Drive.
   - Sequential reading fetches 8 MB chunks ahead in parallel, ramping up the longer reading stays
     sequential, and keeps up to 28 chunks.
   - A jump fetches one 512 KB block, because a Blu-ray seek is many small jumps.
   - **`LocalReader`** reads downloaded films from chunk files on the phone instead.
2. **ReelEngine** is FFmpeg 8.1.3, LGPL parts only, static, built by `Tools/build-ffmpeg.sh` into
   `~/Developer/Reel/vendor/ffmpeg/<sdk>`. Its source tarball was checked file by file against tag n8.1.3.
   It demuxes MKV / M2TS / MP4 and writes **fMP4 HLS segments**:
   - The picture is copied untouched. The H.264/HEVC decoders are linked only to read HDR colour tags;
     without them the HDR tags are lost (tested). Keep them.
   - AC3 / E-AC3 / AAC are copied. DTS / DTS-HD / TrueHD / FLAC become **ALAC** (verified bit-exact).
   - PGS and text subtitles are decoded and **drawn by the app**, not by AVPlayer.
   - Segments start on keyframes from the MKV index, or every 4 s. Decode times are the segment's sorted pts
     minus a fixed delay, so any segment can be made on its own after a seek and comes out identical.
3. A tiny HTTP server on **127.0.0.1** (NWListener) serves the playlist and segments to **AVPlayer**.
   iOS can't play MKV, M2TS or DTS natively, which is why the engine exists.

It starts in about 15 s on a real film, which Bjartur accepted. Most of that time is spent fetching the
opening data from Drive. That is the place to optimise if he ever asks.

### 5.4a Torrents
A magnet link opened in Reel Server downloads straight to Google Drive: the helper `reel-torrent` (libtorrent)
keeps only a few 1 GB parts on the Mac, each part is uploaded and checked against Google's MD5 before it's deleted,
and the finished film joins the library like a Faster Upload. See CLAUDE.md "Torrents straight to Google Drive".

### 5.4b Dolby Vision
UHD Blu-ray Dolby Vision (profile 7, e.g. Casino Royale) is converted to profile 8.1 as it plays, by a small patch to
FFmpeg (`Tools/ffmpeg-dovi-p81.patch`). Apple TV plays such films through the same engine, reading the original from
the Mac, because Jellyfin can only send their HDR10 part. See CLAUDE.md "Dolby Vision".

### 5.5 Drive protocol between Mac and phone (`Shared/PhoneShared.swift`, `Mac/Cloud/PhoneBridge.swift`)
Each tag is an appProperty `reel=<kind>` on a Drive file:

| Kind | Written by | Contents |
|---|---|---|
| `film` / `part` | Mac upload | The original, whole or in 1 GB parts |
| `info` | Mac, PhoneBridge | JSON per verified film: Jellyfin details, artwork, Blu-ray track languages from the disc's .clpi (cached in defaults) |
| `request` | Phone | "Please make a Medium/Low copy of film X" |
| `copy` | Mac, PhoneBridge | The smaller MKV, made with Jellyfin's ffmpeg using VideoToolbox HEVC. Hardware decode is used only for HEVC sources; Blu-ray H.264 is faster in software |
| `watch` | Both | Watch progress, synced ↔ Jellyfin UserData via `POST /UserItems/{id}/UserData`, so the TV and phone share Continue Watching |

PhoneBridge runs every 45 s. Removing a film in Reel Server also bins its iPhone files.

### 5.6 Downloads (`Phone/Downloads.swift`)
- Use a background URLSession and 256 MB ranged pieces, with a fresh token per batch.
- Each finished download is MD5-checked against Drive.
- Original downloads the film itself. Medium/Low sends a `request`, waits for the Mac's `copy`, then
  downloads that.

---

## 6. Google Cloud
- Project `reel-515510`. **Never touch his other project, True Count Academy.**
- Drive API is on, and the OAuth app is External and **In production**.
- Publishing the app required a home page and privacy policy. They're on Firebase Hosting in the same
  project: `https://reel-515510.web.app/` and `/privacy` (noindex). Don't delete the site, and keep the
  policy true if what Reel does with Google data changes.

---

## 7. Building

```bash
bash ~/Reel/setup.sh          # everything: Jellyfin + XcodeGen + Reel Server (installs to ~/Applications) + TV
bash ~/Reel/setup.sh mac      # Mac only
bash ~/Reel/setup.sh tv       # Apple TV only
bash ~/Reel/setup.sh iphone   # iPhone and iPad (every connected one); "ipad" does the same
bash ~/Reel/Tools/build-ffmpeg.sh   # rebuild the FFmpeg libraries (rarely needed)
```
- Source of truth: **`~/Reel`**. `setup.sh` rsyncs it to `~/Developer/Reel/src` (excluding `movies/`) and
  builds there. The log goes to `~/Reel/setup.log`.
- XcodeGen generates the project from `project.yml`; the binary is `~/Developer/Reel/bin/xcodegen`.
  **Never hand-edit the .xcodeproj.**
- Swift language mode 5. Team `9U953J4FPN`.
  - Mac: manual signing, no sandbox or hardened runtime.
  - TV and iPhone: automatic signing with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration`.
- Code is on GitHub at `bjartureinars/reel` (public). Commits carry **no Claude co-author line**, at Bjartur's request.
- Backups: `~/Developer/Reel/backups/` (2026-11-22-pre-cloud*, 2026-11-22-pre-github).
- Machine: Mac mini (Apple silicon), macOS 27.2.1, Xcode 27.2. Disk is tight (about 16 GB free plus the drop folder).

---

## 8. Code map (about 12,000 lines)

```
Shared/   Jellyfin.swift (client + models), Keychain.swift, CloudAPI.swift (TV↔Mac types), PhoneShared.swift (Drive protocol)
Mac/      ReelServerApp, ServerManager, ContentView, CloudView, AppleTVView, FilmManagement
Mac/Cloud GoogleAuth, DriveClient, RemoteFile, CloudFiles, DropInspector, CloudStore, NFSServer, CloudDisk,
          ControlAPI, MiniHTTP, PhoneBridge
TV/       ReelApp, ConnectView, BrowseViews, FilmActions, CloudClient, Player, BitrateOverlay
Phone/    ReelPhoneApp, Support, GoogleAccount, Library, FilmReader, Engine, Player, PlayerView, Downloads,
          Screens, FilmDetailView, Components, Reel-Bridging-Header.h
Engine/   ReelEngine.c / .h
Tools/    build-ffmpeg.sh, step.sh (one-off Jellyfin fetch helper)
project.yml, setup.sh, README.md, CLAUDE.md
```

---

## 9. What's verified and what isn't

**Verified:**
- Upload, verify and delete safety, and streaming the 4K remux through Jellyfin, tested against a fake Drive.
- Casino Royale is in real Drive and reads back at 254–325 Mbps.
- The iPhone app streams real films from Drive on his iPhone 15. Bjartur confirmed this.
- In the simulator: 4K HDR10, resume, PGS subtitles, the bitrate panel and Skyfall's M2TS.

**Not yet verified:**
- A real approval end to end. Skyfall is waiting for approval, and **Bjartur presses that button himself**.
- Download to Mac from real Drive.
- Faster Uploads' read-back from real Drive.
- Playback and the bitrate panel on the physical TV.
- On the iPhone: downloads, Medium/Low copies end to end, watch sync with the TV, PiP, AirPlay.

---

## 10. Working with Bjartur
- Explain in plain, non-technical language. He makes the calls.
- Confirm before moving or deleting any of his media. His Desktop and Documents are in iCloud.
- Don't generate files (PDF, HTML, etc.) unless he asks for one.
- Never put his email or personal details into requests to outside services.
- No Claude co-author or attribution lines in commits.
