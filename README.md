# Now Playing

Now Playing is a small macOS menu bar app that shows the currently playing track in the system status bar.

It displays the current title and artist alongside an SF Symbol icon that reflects playback state, and supports click-and-scroll controls for play/pause/next/previous.

## Requirements

- macOS 12 or newer (developed and tested on macOS 26)
- Apple Music, Spotify, Safari, or another app that publishes now-playing metadata through macOS MediaRemote

## Download

Download the latest release from GitHub, unzip `NowPlaying.app`, and open it.

Because release builds are ad-hoc signed and may not be notarized, macOS can show a first-launch warning. If that happens, use Finder to Control-click the app, choose Open, and confirm the launch.

## Usage

After launch, Now Playing runs as a menu bar app. It does not show a Dock icon.

- The menu bar text shows the current title and artist.
- The icon reflects state: `play.fill` while playing, `pause.fill` while paused, `waveform` when nothing is loaded.
- **Left-click** the menu bar item to toggle play/pause.
- **Right-click** (or Control-click) to open a dropdown with Play/Pause, Next Track, Previous Track, Refresh, and Quit.
- **Scroll** the wheel/trackpad over the icon: up advances to the next track, down to the previous.

### Accessibility permission

Playback controls are sent as synthetic media-key events. The first time the app posts one, macOS will prompt you to grant Accessibility permission (System Settings → Privacy & Security → Accessibility). Toggle it on for `NowPlaying`, then quit and relaunch the app. Subsequent launches keep the permission as long as the build is signed with the same code-signing identity.

## Build From Source

The project builds with the tools included in Xcode Command Line Tools:

```sh
./build.sh
```

The built app is written to:

```text
build/NowPlaying.app
```

Run it with:

```sh
open build/NowPlaying.app
```

### Code signing for development

`build.sh` signs the app with a code-signing identity named `dj`. If you want Accessibility permission to persist across rebuilds (highly recommended during development), create a self-signed code-signing certificate in Keychain Access named `dj` (or edit `build.sh` to use whatever name you choose):

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Identity Type: **Self Signed Root**, Certificate Type: **Code Signing**
3. After creation, set the certificate's **Code Signing** trust to **Always Trust**.

Without a stable signing identity (i.e. with ad-hoc signing), every rebuild produces a new code-directory hash and macOS will re-prompt for Accessibility permission.

## How It Works

The Swift app owns the menu bar UI and periodically asks a small adapter for now-playing data. The adapter is an Objective-C dynamic library loaded by `/usr/bin/perl`, then calls Apple's private `MediaRemote.framework` and prints a JSON object back to the Swift app.

The perl-loader indirection exists because, starting in macOS 15.4, Apple restricted `MRMediaRemoteGetNowPlayingInfo` so that third-party apps receive empty data when calling it directly. Apple-signed `/usr/bin/perl` retains the necessary access, so loading our minimal adapter dylib from perl is enough to read the live playback state.

The technique was inspired by [kirtan-shah/nowplaying-cli](https://github.com/kirtan-shah/nowplaying-cli); the dylib in this repo is a minimal re-implementation that exposes a single `adapter_get` function returning title/artist/album/playing.

Playback controls (`play`, `next`, `previous`) take a different path. `MRMediaRemoteSendCommand` is locked down even more aggressively than the read API, so Now Playing instead synthesizes the corresponding hardware media-key events with `NSEvent.systemDefined` and posts them to the system event tap. This delivers the command to whichever app currently owns the Now Playing session.

This approach is intentionally small and local, but it depends on private macOS APIs and on hardware-key synthesis. Apple can change MediaRemote behavior in future macOS releases.

## Current Limitations

- Metadata refreshes by polling every 4 seconds (with an immediate refresh after any user-issued command, so clicks and scroll feel instant).
- The title shown is whatever the source app publishes to MediaRemote. Some apps (notably YouTube Music in browsers) publish only the romanized/English form of bilingual titles, so the original-script title may not appear.
- The app uses private MediaRemote APIs and synthetic media keys, so compatibility is not guaranteed across all macOS versions.
