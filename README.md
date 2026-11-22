# Reel

Your own Apple TV film service, served from your Mac mini.

- **Reel Server** (Mac): runs a Jellyfin 12.4 server for you, with no web setup. Put films in `~/Reel/movies`
  (or drag them into its window) and approve each one under **Google Drive** in Reel Server. It then appears
  on the TV, uploads to Google Drive, and is deleted from the Mac once Google's copy is verified.
  Don't make that folder a download app's save location.
  A Blu-ray folder is offered as one film; its menus and extras are never uploaded.
  It lives in the menu bar, keeps the Mac awake while something streams, and shows whether the TV is
  getting the original picture.
- **Reel** (Apple TV): finds the Mac by itself, pairs with a six-digit code, and plays in Apple's own player.
  4K HDR10 and Dolby Vision video is sent untouched (direct play, or remuxed bit-for-bit from MKV);
  only audio Apple TV can't decode (DTS, TrueHD) is converted to Dolby Digital Plus. Resume positions sync.

- **Reel** (iPhone): streams the original film straight from Google Drive, anywhere, with no Mac in the way.
  The picture is untouched; DTS and TrueHD sound becomes Apple Lossless on the phone with nothing lost; Blu-ray
  subtitles are drawn by the app. Download films to watch offline, as the original or as a Medium (1080p) or
  Low (720p) copy that Reel Server makes the first time someone asks. Where you got to syncs with the Apple TV.

## Set up

1. Run `bash ~/Reel/setup.sh` in Terminal. It downloads Jellyfin (checksum-verified), builds
   Reel Server, installs it to ~/Applications and opens it.
2. Pair the Apple TV with Xcode once (the script prints the steps), then run `bash ~/Reel/setup.sh tv`.
3. For the iPhone, connect it with a cable and run `bash ~/Reel/setup.sh iphone`, then sign in with Google in Reel.
3. Open Reel on the Apple TV. It shows a code; in Reel Server click **Connect Apple TV** and type it.

Apps installed from Xcode with a paid developer account stay valid for a year; run `setup.sh tv` again to renew.

## Google Drive

- Connect once in Reel Server → **Google Drive** (it lists the steps).
- On the TV, open a film: **Stream** plays it from Google through the Mac in original quality;
  **Download to Mac** fetches it first, replacing the previously downloaded film.
- The speedometer button in the player shows or hides the live bitrate.
- Reel Server must be running for either option. Google holds the only copy once a film is offloaded.

## Notes

- Turn on **Match Content → Match Dynamic Range** and **Match Frame Rate** in the Apple TV's Settings → Video and Audio.
- Ethernet on both the Mac and the Apple TV is best for 4K remuxes (60–100 Mbit/s).
- Dolby Vision profile 5 and 8 play as Dolby Vision; profile 7 (UHD Blu-ray) plays as HDR10, its base layer.
- Jellyfin is free software (GPL-2.0) by the Jellyfin project. Reel talks to it through its public API.
