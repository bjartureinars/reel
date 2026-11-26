# Reel — handoff notes for Claude Code

Personal project of Bjartur (Reykjavík). Two apps that turn his Mac mini into a private film service for
his Apple TV, built on Jellyfin, designed with the apple-design skill (Apple HIG):

- **Reel Server** (macOS, SwiftUI): runs and auto-configures a Jellyfin 12.4 server as a child process;
  drag-and-drop library; Bonjour advertising; Quick Connect pairing; menu bar extra; keeps Mac awake while streaming.
- **Reel** (tvOS, SwiftUI): Bonjour discovery → Quick Connect code pairing → Home / Films /
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

## TV shows (2026-11-23)

- Second drop folder **`~/Reel/tv shows`** (`CloudPaths.shows`): one folder per show, seasons inside, or loose
  `Show.S01E02.mkv`. `DropInspector.scan(_, shows: true)` files each episode as folder `TV Shows/<Show>/Season NN`
  (season from SxxEyy/1x02, else a "Season N" folder; no BDMV handling for shows). Same approval gate and
  upload → verify → delete; `Upload All N` button approves every ready episode of a show (still per-item checks).
- `CloudFilm.folder` can be a path; NFS disk has nested folders: top folders keep ids 2…, inner folders get
  FNV ids ≥ 1<<62 (film ids are < 1<<62). `CloudStore.folders` = Films, Home Videos, TV Shows (order fixes ids).
- Jellyfin library "TV Shows" (tvshows) on `~/Movies/Reel/TV Shows` + mount `TV Shows`. Reel Server: TV Shows page,
  show window (Identify Show via `RemoteSearch/Series`, posters, episode list, Delete Show = every episode).
- Apple TV: TV Shows tab, `TV/ShowViews.swift` (ShowView: next-up Play/Resume, seasons, EpisodeCard with
  watched/unwatched), Home "Next Up" + "Recently Added TV Shows", episodes open their show; next episode autoplays.
- iPhone/iPad: Drive `show` files (`ShowInfo`, one per Jellyfin series) + `FilmInfo.episode` (`EpisodeRef`);
  episode picture = still in backdrop, show poster `show-<id>-poster.jpg`. `Phone/ShowViews.swift`; Home Next Up;
  next episode autoplays. iPhone has 5 tabs (Settings from a gear on Home; iPad keeps a Settings tab).
- Fixed 2026-11-24: the phone rebuilt `FilmInfo` without new fields (lost `episode`); now it only clears
  poster/backdrop (`var`), and the revision key is `info.rev2.<id>` so old details were re-read.
  Jellyfin kept items from an emptied local library folder (it treats empty roots as offline):
  `ServerManager.removeVanished()` deletes Jellyfin items in Reel's *local* library folders whose path has
  nothing at all (not even a link); never on the Drive disk. Runs at start and after each scan.
- `setup.sh` rsync must exclude every media folder in ~/Reel (`/movies`, `/tv shows`): it once copied 33 GB
  of episodes into ~/Developer/Reel/src and filled the disk.
- Test episode (Friends S01E01) was **incomplete** (7.4 GB file, 1.4 GB on disk), so Reel correctly blocks it.
  Not yet verified: a real show end to end through Drive, the TV screens on the Apple TV (no tvOS simulator here).

## Versions and extras (2026-11-26)

- Catalog (`CloudFilm`): `versionOf` → the group's default version, `versionLabel`, `extraOf` + `extraKind` (`ExtraKind` in
  PhoneShared, with Jellyfin folder names) + `extraTitle`, `groupFolder` ("Title (Year)") on the default. Nothing moves in
  Drive: `CloudStore.place()` shows a grouped film on the cloud disk as `Films/<group>/<group> - <Label>.ext` and extras in
  `Films/<group>/trailers|behind the scenes|featurettes|deleted scenes|interviews|shorts|extras/<title>.ext`, which Jellyfin
  turns into one film with alternate versions (PrimaryVersionId) and extras (OwnerId, ExtraType). Use `place()`/`diskName()`
  wherever a film's disk path or name matters (film(atDiskPath:), namesPlaying).
- Jellyfin makes the highest resolution its primary; the **default** is Reel's: `FilmStatus.versionLabel/isDefaultVersion/
  extraTitle` (per version via its media source id = its own item id). TV `DetailView`: scrolling page, VERSIONS/EXTRAS tab
  row (gold underline, tab follows focus), `VersionCard` plays that version (`PlaybackController.play(version:)` →
  PlaybackInfo `MediaSourceId`), `ExtraCard` from `/Items/{id}/LocalTrailers` + `SpecialFeatures`. `FilmActions(version:)`.
- Reel Server film window: Details | Versions | Extras tabs (`Mac/FilmGroups.swift`): add version from library (search with one
  match auto-selects), rename, Make Default, Separate; extras from this Mac (copied into hidden `~/Reel/movies/.reel-extras`,
  choosing = approval, normal upload/verify/delete of the copy) or from library, kind and title editable. The window tracks
  the film by catalog id (`filmID`), since grouping changes its path. Watch progress is copied to the moved film after the
  next scan (`carryWatchState`). Removing a default version promotes the next; with none left its extras go too.
- iPhone: PhoneBridge expands a grouped item into one info per version (media source path/streams/id) and fetches extras;
  `FilmInfo.filmVersion` (`VersionRef`) / `.extra` (`ExtraRef`). Phone lists only default versions; film page has a
  Versions/Extras segmented section; rows play, long-press = FilmMenu.
- `setup.sh` now waits for Reel Server to quit and ends it if a window blocks the quit (it used to stop Jellyfin and leave
  the old app running with "The server stopped").
- Verified 2026-11-26 with three test clips ("Reel Test Film" 2160p/1080p + Official Trailer, left in his library for him to
  try): grouping, Make Default, extra from library, Jellyfin grouping and extra type. Also verified: Add from This Mac with
  his trailer for Revenge of the Sith (`~/Reel/extras`, his test folder, excluded from setup.sh rsync and Git): original
  kept, copy uploaded/verified/deleted, Jellyfin Trailer owned by the film, watch progress (52 min) carried over.
  Not verified: the TV and iPhone screens on devices.

## Torrents straight to Google Drive (2026-11-25)

- Magnet links open Reel Server (`CFBundleURLTypes` magnet; File → Add Magnet Link… ⇧⌘M). uTorrent is still his
  default magnet app; the Add Torrent window has a button to make Reel Server the default (macOS asks him).
- Helper `Tools/reel-torrent/main.cpp` (libtorrent 2.1.3 static + Homebrew Boost headers + static OpenSSL, built by
  `Tools/build-torrent.sh`, embedded in Contents/MacOS by a project.yml post-build script). Own `disk_interface`:
  pieces in workdir/pieces, a file's 1 GiB parts assembled in workdir/parts, pieces deleted once every part they
  touch is assembled. A read of a deleted piece fails → libtorrent sends DONT_HAVE + reject (never wrong data).
  Only pieces of the next `window` parts not yet in Drive get priority; window = free space − 10 GB, 1…4 parts.
  Reconciles with libtorrent's piece bitfield every second (alerts can be dropped); deadlines on a part's last 5%.
  Line protocol on stdin/stdout documented at the top of main.cpp. Resume = resume.dat (info dict) + piece files.
- `Mac/Cloud/TorrentStore.swift`: jobs in `~/Library/Application Support/Reel/torrents/torrents.json` + one workdir
  each. Parts upload as `reel=part` files (same layout as Faster Uploads, extra `source=torrent`), Drive MD5 must
  equal the local MD5 before `uploaded k` lets the helper delete it; all parts → `CloudStore.adoptFromTorrent` (verified).
  Approval = pressing Download in the Add Torrent window on the Mac; never accept magnets over port 8097.
- Network: his Mac runs a **VPN** (`utun7`, all traffic through it) and **uTorrent** (holds port 6881). The helper
  listens on the interface that routes 1.1.1.1 (REEL_LISTEN=<iface>:0, random port) and is restarted if that changes,
  so torrent traffic always follows the VPN. Binding to en1 gave "No route to host" (VPN blocks it). DHT needs
  explicit `dht_bootstrap_nodes` (none by default in this build).
- Speed fixes 2026-11-26 (downloads had nearly stalled):
  1. **Lost `start` after every helper restart** (Reel Server restart, VPN reconnect): `start` arrived before the
     resumed torrent loaded and was dropped ("details haven't arrived yet"), leaving it connected but idle. The helper
     now holds `start`/`uploaded` until the torrent is loaded.
  2. `announce_to_all_trackers` + `announce_to_all_tiers` (default stopped at the first tracker, ~20 peers, 1 h interval);
     re-announce to trackers + DHT every 5 min while under 40 peers. A probe then got 6 trackers, 67 peers, ~160 Mbit/s.
  3. Several files at once: `start` queues a file, one budget of `window` parts across the queue (season packs no longer
     alternate download/upload). Protocol now `part <file> <k> …`, `uploaded <file> <k>`, `complete <file>`.
  4. Drive lanes: every part used lane 0 (`key % 8` with key = file*100000+k). Now the least-busy of 8 lanes;
     window = share of (free − 10 GB) per running torrent, 1…8 parts. Torrent upload limit 2 MB/s per helper.
  After: 72 Mbit/s down, 68 Mbit/s to Drive. His uplink through the VPN is ~70–100 Mbit/s: that's the ceiling.
  Helper restarts also follow a VPN address change on the same interface name.
- Naming: torrent episodes take the show from the file name, else the torrent's title without season/quality words;
  an existing show with a similar name is reused ("The office" for "The Office (US) (2005)"); bonus material
  (Featurettes/Extras/Deleted Scenes folders) goes to "<Show> Extras" and isn't ticked by default. Numbered Blu-ray
  clips take the torrent's name (`filmName`). `refileOldNames()` moved older items via `CloudStore.refile`; he OK'd it
  2026-11-26 (defaults `refileTorrentNames` = true; it runs at each start and is a no-op once names match).
  The Office torrent job includes 180 bonus files: he wants them (2026-11-26), don't skip extras.
  `ServerManager.dressExtrasShows()` (after scans/start) gives a "<Show> Extras" series its show's poster/backdrop
  when it has none. PhoneBridge numbers unnumbered episodes from their "Season NN" folder and "Exx" in the name.
- Verified 2026-11-25: Big Buck Bunny magnet in 16 MB parts → SHA-256 identical to a direct download, peak 34 MB on
  disk; stop/resume mid-way identical; real run magnet → Drive → catalog → Jellyfin, read back from Drive identical,
  then deleted (Drive's Bin). Ubuntu ISO hit 219 Mbit/s before its tracker started answering 503 to repeated tests.
  Not yet verified: a real multi-GB film, a TV season pack, VPN switching mid-download.

## iPhone/iPad polish (2026-11-24)

- `FilmMenu` + `FilmPreview` (Components.swift): one long-press menu on every film/episode card (Play/Resume, Play from
  Beginning, My List, Mark Watched, Download/Remove, Remove from Continue Watching last and destructive). Show cards: play next.
- Player: Speed menu (`defaultRate`), Next Episode button; the next episode still starts at the end of one.
  Opening a player menu cancels the controls' auto-hide (it used to close menus).
  **Removed at his request (2026-11-24): the Up Next card and Smart Downloads. Don't add them back.**
- Details: More Like This (genre overlap, `Library.similar`), episodes show "More from <show>". Show page: Download Season
  (confirmation with total size per quality) / remove season downloads, More Like This shows.
- Home genre rows (genres with ≥ 3 films, max 4). Search: recent searches (8, on device, Clear). Home Screen quick actions:
  Resume <title>, Search, Downloads (`SceneDelegate`, `AppModel.tab`).
- Verified in the simulator with the real Friends file (`REEL_FILE_<id>` hook): menus, Next Episode, season download dialog.
  Not verified on device: speed menu (simulator taps fought the auto-hide), quick actions.

## Dolby Vision (2026-11-23)

- Casino Royale is DV **profile 7.6 MEL** (UHD Blu-ray; enhancement layer empty: identity mapping, NLQ zero). Apple devices
  can't play P7. Jellyfin's remux uses `hevc_metadata=remove_dovi=1` → HDR10 only; jellyfin-ffmpeg can't convert P7.
- Reel converts P7 → **8.1** itself: `Tools/ffmpeg-dovi-p81.patch` adds `to_p81` to FFmpeg's `dovi_rpu` bsf (drops
  UNSPEC63 EL NALs, sets disable_residual/el_spatial flags, identity mapping, no NLQ; config record profile 8, compat 1).
  `build-ffmpeg.sh` applies it and now also builds appletvos/appletvsimulator (`bash Tools/build-ffmpeg.sh appletvos ...`).
- Engine (`ReelEngine.c`): per segment a fresh bsf when the source is P7; output `hvc1` + `dvvC` (strict unofficial);
  P5/P8 sources keep their DV box now (P5 as `dvh1`). `reel_codecs` gives HLS CODECS/SUPPLEMENTAL-CODECS ("L" tier like Jellyfin).
- Verified on this Mac: all frames parse with valid DV 8.1 RPUs; L1/L2/L4/L5/L6 identical to the original; AVPlayer decodes
  with `DolbyVisionRPUData` attachments. This Mac isn't HDR-eligible, so master playlists with VIDEO-RANGE=PQ can't be tested here.
- **Apple TV**: for `DvProfile == 7` it no longer uses Jellyfin's remux. `TV/EnginePlayback.swift` reads the original
  via `/Videos/{id}/stream?static=true` in byte ranges (`RangeReader`), runs the shared engine and plays `master.m3u8`
  (VIDEO-RANGE, SUPPLEMENTAL-CODECS for the TV's DV mode switch); falls back to `film.m3u8` if AVPlayer rejects it.
- Shared engine code moved: `Engine/EngineMedia.swift` (was Phone/Engine.swift), `Engine/RangeReader.swift` (generic
  read-ahead; `DriveReader` is now a subclass). TV target compiles `Engine/` with its own bridging header.
- Not yet verified on real hardware: DV on the TV (needs a DV TV; Settings → Video and Audio shows it), DV on iPhone 15/iPad.

## iPad (2026-11-23)

- ReelPhone is universal (`TARGETED_DEVICE_FAMILY "1,2"`, all four iPad orientations); installed on his iPad Air 11-inch (M3)
  and iPhone. `bash ~/Reel/setup.sh ipad` (= `iphone`) builds and installs on every paired iPhone and iPad.
- iPad layout: `.tabViewStyle(.sidebarAdaptable)`, `Metrics` (Support.swift) sizes by horizontal size class,
  detail text column max 720 pt, `Device.name` says iPhone/iPad in text. Checked in the iPad simulator, portrait and landscape.
- Disk is nearly full (1.7 GB free on 2026-11-23); `~/Reel/movies/untitled folder` holds 57 GB of his. Don't build
  for simulators into new folders without checking `df` first.

## Films only, and film management (2026-11-23)

- Home Videos removed everywhere at his request (TV tab and shelf, iPhone shelf and picker, Mac sidebar and menu).
  Reel Server deletes Jellyfin's "Home Videos" library only while it's empty; `~/Movies/Reel/Home Videos` is left on disk.
  DropInspector now treats everything in the drop folder as Films. `CloudStore.folders` still lists both (NFS node ids).
- `Mac/FilmManagement.swift`: clicking a film in Reel Server opens a window with Identify Film (Jellyfin
  `RemoteSearch/Movie` + `RemoteSearch/Apply`, searches with and without the year because Jellyfin's guessed year is
  often wrong), Change Poster / Change Backdrop (`RemoteImages`, or his own file → JPEG → `POST /Items/{id}/Images/{type}`,
  raw first then base64), and Delete from Google Drive (existing `removeFromLibrary`: Drive's Bin, 30 days).
  A new backdrop replaces the old ones. iPhone picks up changes via PhoneBridge's revision (image tags) and
  `Artwork` now keys its cache by file date.
- Verified on a test clip: identify, database poster, database backdrop, Move to Trash. **Not verified**: uploading his
  own picture (the macOS Open panel can't be driven from the background), Delete from Google Drive on a real film.

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
