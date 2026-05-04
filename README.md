# Now Playing

Now Playing is a lightweight macOS menu bar app for seeing and controlling the current media session without opening the player.

It shows the current title and artist in the system status bar, updates the icon for playing/paused/idle state, and sends play/pause/next/previous commands through the same media-key path used by hardware keyboards.

## Features

- Menu bar display for the current track title and artist
- Hover for a tooltip with the full untruncated title, artist, and album
- Custom macOS app icon for Finder, launch prompts, and system permission dialogs
- Playback-state icons: `play.fill` while playing, `pause.fill` while paused, and `waveform` when idle
- Optional source-app icon in the menu bar when the current player can be identified
- Left-click to toggle play/pause
- Right-click or Control-click for a dropdown menu with the app version, current Accessibility-permission status, and Play/Pause, Next Track, Previous Track, Copy, Refresh, Show Source App Icon, Open at Login, and Quit
- Scroll over the menu bar item to change tracks: up for next, down for previous
- Copy the current `Title — Artist` to the clipboard from the menu (or ⌘C while the menu is open)
- Optional "Open at Login" toggle so the app starts with macOS
- Local-only operation: no accounts, servers, analytics, or network calls

## Requirements

- macOS 12 or newer
- A media app that publishes now-playing metadata through macOS, such as Apple Music, Spotify, Safari, or a browser-based player
- Accessibility permission for playback controls

Now Playing was developed and tested on macOS 26. It uses private macOS MediaRemote APIs, so compatibility can change with future macOS releases.

## Install

Download the latest release archive, unzip it, and move `NowPlaying.app` wherever you keep local apps.

Current release builds are signed for local distribution and may not be notarized. On first launch, macOS may show a security warning. If that happens, Control-click `NowPlaying.app` in Finder, choose **Open**, then confirm.

After launch, the app appears only in the menu bar. It does not show a Dock icon.

## Controls

- **Left-click:** toggle play/pause
- **Right-click or Control-click:** open the menu
- **Scroll up over the item:** next track
- **Scroll down over the item:** previous track
- **Hover (≈2 s):** tooltip with full title, artist, and album
- **Copy menu item (or ⌘C):** put the current `Title — Artist` on the clipboard
- **Show Source App Icon menu item:** switch between generic playback-state symbols and the current player's app icon
- **Open at Login menu item:** toggle whether the app starts automatically at login (macOS 13+)
- **Refresh menu item:** manually reload current metadata
- **Quit menu item:** exit the app

The menu also shows the running app version and the current Accessibility permission status. If permission is denied, clicking the status line opens System Settings directly to the right pane.

## Accessibility Permission

Playback controls are sent as synthetic media-key events. The first time Now Playing sends one, macOS should prompt for Accessibility permission.

Grant permission in:

```text
System Settings → Privacy & Security → Accessibility → NowPlaying
```

After enabling it, quit and relaunch Now Playing. If you rebuild the app yourself with a different signing identity, macOS may treat it as a new app and ask for permission again.

## Build From Source

Build with Xcode Command Line Tools:

```sh
./build.sh
```

The app is created at:

```text
build/NowPlaying.app
```

Run it with:

```sh
open build/NowPlaying.app
```

## How It Works

The Swift app owns the menu bar UI and periodically asks a small adapter for now-playing data. The adapter is an Objective-C dynamic library loaded by `/usr/bin/perl`; it calls Apple's private `MediaRemote.framework` and prints JSON back to Swift.

The perl-loader path is used because recent macOS versions restrict direct third-party calls to `MRMediaRemoteGetNowPlayingInfo`. Apple-signed `/usr/bin/perl` still has the required access, and the adapter runs in that process.

The now-playing metadata approach was inspired by [kirtan-shah/nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli). This repo includes a minimal reimplementation tailored for the app, exposing title, artist, album, source app bundle identifier, and playing state through a single `adapter_get` function.

Playback controls use a separate path. `MRMediaRemoteSendCommand` is more restricted on recent macOS versions, so Now Playing posts synthetic hardware media-key events with `NSEvent.systemDefined` and `CGEvent.post`.

## Limitations

- Metadata refreshes by polling every 4 seconds, with quick follow-up refreshes after user commands.
- Some players publish incomplete or transformed metadata; for example, browser-based music sites may expose only romanized titles.
- MediaRemote is a private framework, and synthetic media-key behavior is controlled by macOS. Future macOS updates may require changes.
