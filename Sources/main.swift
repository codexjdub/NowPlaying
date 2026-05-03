import Cocoa
import Foundation

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

        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var client: NowPlayingClient?
    private var timer: Timer?
    private let maxLength = 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Now Playing")
            icon?.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeft
            button.title = ""
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        client = NowPlayingClient()
        guard client != nil else {
            statusItem.button?.title = "Unavailable"
            return
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

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
        let display: String
        if let info = info, let title = info.title, !title.isEmpty {
            if let artist = info.artist, !artist.isEmpty {
                display = "\(title) — \(artist)"
            } else {
                display = title
            }
        } else {
            display = ""
        }
        statusItem.button?.title = truncate(display)
    }

    private func truncate(_ s: String) -> String {
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength - 1)) + "…"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
