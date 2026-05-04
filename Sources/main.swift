import Cocoa
import Foundation
import ApplicationServices
import ServiceManagement

// HID media-key codes (from IOKit/hidsystem/ev_keymap.h, NX_KEYTYPE_*).
private enum MediaKey: Int {
    case play     = 16
    case next     = 17
    case previous = 18
}

/// Post a synthetic media-key press (down + up) so the system delivers it to
/// whichever app currently owns the Now Playing session — Spotify, browsers
/// playing YouTube Music, Apple Music, etc.
///
/// Requires Accessibility permission (System Settings → Privacy & Security →
/// Accessibility). The first call from an unprivileged process triggers the
/// system prompt automatically when `prompt` is true.
private func postMediaKey(_ key: MediaKey, promptIfNeeded: Bool = true) {
    if promptIfNeeded {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    func send(state: Int) {
        let data1 = (key.rawValue << 16) | (state << 8)
        let flags = NSEvent.ModifierFlags(rawValue: UInt(state) << 8)
        guard let nsEvent = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ), let cgEvent = nsEvent.cgEvent else { return }
        cgEvent.post(tap: .cghidEventTap)
    }
    send(state: 0xA) // key down
    send(state: 0xB) // key up
}

struct NowPlayingInfo {
    let title: String?
    let artist: String?
    let album: String?
    let playing: Bool
}

final class NowPlayingClient {
    private let perlPath = "/usr/bin/perl"
    private let scriptPath: String
    private let dylibPath: String

    init?() {
        guard let resources = Bundle.main.resourcePath else { return nil }
        self.scriptPath = (resources as NSString).appendingPathComponent("adapter.pl")
        self.dylibPath  = (resources as NSString).appendingPathComponent("MediaRemoteAdapter.dylib")

        let fm = FileManager.default
        guard fm.isReadableFile(atPath: scriptPath),
              fm.isReadableFile(atPath: dylibPath) else { return nil }
    }

    func fetch() -> NowPlayingInfo? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: perlPath)
        task.arguments = [scriptPath, dylibPath, "adapter_get"]

        let stdoutPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = FileHandle(forWritingAtPath: "/dev/null")

        // Wait with a 2 s deadline so a hung perl can't block the worker
        // thread indefinitely (and pile up workers across polling ticks).
        let sem = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in sem.signal() }

        do { try task.run() } catch { return nil }

        if sem.wait(timeout: .now() + 2.0) == .timedOut {
            task.terminate()
            _ = sem.wait(timeout: .now() + 0.5) // give SIGTERM a moment to land
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return nil
        }

        return NowPlayingInfo(
            title:   dict["title"]   as? String,
            artist:  dict["artist"]  as? String,
            album:   dict["album"]   as? String,
            playing: (dict["playing"] as? Bool) ?? false
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var client: NowPlayingClient?
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var menu: NSMenu!
    private var versionItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var copyItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem?
    private var lastInfo: NowPlayingInfo?
    private var lastScrollAt: TimeInterval = 0
    private let scrollCooldown: TimeInterval = 0.4
    private let maxLength = 45        // total cap for "Title — Artist"
    private let maxArtistLength = 25  // artist trims past this
    private let minTitleLength = 10   // title gets at least this many chars

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Now Playing")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeft
            button.title = ""

            // Receive both left and right click events so we can branch behavior.
            button.target = self
            button.action = #selector(handleStatusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Build (but don't attach) the dropdown menu — we attach it on demand
        // for right-clicks, otherwise left-click would also pop the menu.
        menu = NSMenu()
        menu.delegate = self
        let addItem: (String, Selector, String) -> Void = { [weak self] title, sel, key in
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            item.target = self
            self?.menu.addItem(item)
        }

        // Header: app version + Accessibility status. Both updated on menuWillOpen.
        versionItem = NSMenuItem(title: "NowPlaying", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        accessibilityItem = NSMenuItem(title: "Accessibility: …", action: nil, keyEquivalent: "")
        menu.addItem(versionItem)
        menu.addItem(accessibilityItem)
        menu.addItem(NSMenuItem.separator())

        addItem("Play / Pause",   #selector(toggle),   "")
        addItem("Next Track",     #selector(next),     "")
        addItem("Previous Track", #selector(previous), "")
        menu.addItem(NSMenuItem.separator())

        copyItem = NSMenuItem(title: "Copy", action: #selector(copyTrackInfo), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)
        menu.addItem(NSMenuItem.separator())

        if #available(macOS 13.0, *) {
            let item = NSMenuItem(title: "Open at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            item.target = self
            launchAtLoginItem = item
            menu.addItem(item)
            menu.addItem(NSMenuItem.separator())
        }

        addItem("Refresh", #selector(refresh), "r")
        menu.addItem(NSMenuItem.separator())
        addItem("Quit", #selector(quit), "q")

        client = NowPlayingClient()
        guard client != nil else {
            statusItem.button?.title = "Unavailable"
            return
        }

        // Listen for scroll-wheel events over the menu bar item.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
            return event
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func handleStatusClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            // Pop the menu directly anchored to the button. This avoids the
            // attach/perform/detach race that can dismiss the menu instantly.
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
        } else {
            send(.play)
        }
    }

    /// Post a media key and schedule a couple of refreshes so the menu bar
    /// catches the new track/state quickly instead of waiting for the next
    /// polling tick. Two delays cover fast players (Spotify/Music) and
    /// slower ones (browser-based YouTube Music).
    private func send(_ key: MediaKey) {
        postMediaKey(key)
        for delay in [0.2, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    private func handleScroll(_ event: NSEvent) {
        // Only react to scrolls aimed at our status item's window.
        guard let buttonWindow = statusItem.button?.window,
              event.window === buttonWindow else { return }

        let dy = event.scrollingDeltaY
        if abs(dy) < 1.0 { return }

        let now = Date().timeIntervalSince1970
        if now - lastScrollAt < scrollCooldown { return }
        lastScrollAt = now

        if dy > 0 {
            send(.next)
        } else {
            send(.previous)
        }
    }

    @objc private func toggle()   { send(.play) }
    @objc private func next()     { send(.next) }
    @objc private func previous() { send(.previous) }

    @objc private func refresh() {
        guard let client = client else { return }

        // Run the perl invocation off the main queue (it can take ~50–200ms)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = client.fetch()
            DispatchQueue.main.async {
                self?.update(with: info)
            }
        }
    }

    private func update(with info: NowPlayingInfo?) {
        lastInfo = info
        let display: String
        let symbolName: String
        let tooltip: String?
        if let info = info, let title = info.title, !title.isEmpty {
            symbolName = info.playing ? "play.fill" : "pause.fill"
            display = format(title: title, artist: info.artist)
            tooltip = buildTooltip(title: title, artist: info.artist, album: info.album)
        } else {
            symbolName = "waveform"
            display = ""
            tooltip = nil
        }

        if let button = statusItem.button {
            if button.image?.accessibilityDescription != symbolName {
                let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName)
                icon?.isTemplate = true
                button.image = icon
            }
            // Prefix a space so the title doesn't sit flush against the icon.
            // (NSStatusBarButton has no imagePadding property.)
            button.title = display.isEmpty ? "" : " " + display
            button.toolTip = tooltip
        }
    }

    /// Build the hover tooltip: full untruncated `Title — Artist` on the first
    /// line, and `Album` on the second line if available.
    private func buildTooltip(title: String, artist: String?, album: String?) -> String {
        var line1 = title
        if let artist = artist, !artist.isEmpty {
            line1 += " — \(artist)"
        }
        if let album = album, !album.isEmpty {
            return line1 + "\n" + album
        }
        return line1
    }

    /// Compose a "Title — Artist" string that fits within maxLength characters,
    /// preferring to truncate the title rather than the artist.
    private func format(title: String, artist: String?) -> String {
        guard let artist = artist, !artist.isEmpty else {
            return shorten(title, to: maxLength)
        }
        let artistShort = shorten(artist, to: maxArtistLength)
        let separator = " — "
        let artistSegment = separator + artistShort
        let availableForTitle = max(minTitleLength, maxLength - artistSegment.count)
        return shorten(title, to: availableForTitle) + artistSegment
    }

    private func shorten(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(max(1, limit - 1))) + "…"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Refresh the header items (version + Accessibility) right before the
    // menu is shown, so the Accessibility line reflects current TCC state.
    func menuWillOpen(_ menu: NSMenu) {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        versionItem.title = "NowPlaying \(version)"

        let granted = AXIsProcessTrusted()
        if granted {
            accessibilityItem.title = "Accessibility: granted"
            accessibilityItem.action = nil           // disabled / informational
            accessibilityItem.target = nil
        } else {
            accessibilityItem.title = "Accessibility: denied — click to fix"
            accessibilityItem.action = #selector(openAccessibilitySettings)
            accessibilityItem.target = self
        }

        // Reflect current Login Items state.
        if #available(macOS 13.0, *), let item = launchAtLoginItem {
            item.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    // Disable the Copy item when there's nothing to copy.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === copyItem {
            return (lastInfo?.title?.isEmpty == false)
        }
        return true
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func copyTrackInfo() {
        guard let info = lastInfo, let title = info.title, !title.isEmpty else { return }
        let text: String
        if let artist = info.artist, !artist.isEmpty {
            text = "\(title) — \(artist)"
        } else {
            text = title
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @available(macOS 13.0, *)
    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't update Login Items"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
