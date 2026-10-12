import AppKit
import ServiceManagement

// MARK: - Now Playing

struct NowPlaying: Decodable, Equatable {
    var playing: Bool
    var app: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: Double?
    var elapsed: Double?
    var rate: Double?
    var timestamp: Double?

    var trackKey: String { "\(artist ?? "")|\(title ?? "")" }

    /// Playback position right now, extrapolated from the last reported elapsed time.
    var position: Double {
        let e = elapsed ?? 0
        guard let ts = timestamp, ts > 0, let r = rate, r > 0 else { return e }
        return e + (Date().timeIntervalSince1970 - ts) * r
    }
}

final class NowPlayingWatcher {
    var onChange: ((NowPlaying) -> Void)?
    private var process: Process?
    private var buffer = Data()

    func start() {
        guard let script = Bundle.main.path(forResource: "nowplaying", ofType: "js") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", script]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.consume(d) }
        }
        p.terminationHandler = { [weak self] _ in
            // Restart the helper if it ever dies.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.start() }
        }
        try? p.run()
        process = p
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let np = try? JSONDecoder().decode(NowPlaying.self, from: line) { onChange?(np) }
        }
    }
}

// MARK: - Lyrics

struct LyricLine { let time: Double; let text: String }

enum Lyrics {
    case synced([LyricLine])
    case plain([String])
    case instrumental
    case none
}

private struct LrclibTrack: Decodable {
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsFetcher {
    static func fetch(_ np: NowPlaying) async -> Lyrics {
        let artist = np.artist ?? "", title = np.title ?? ""
        guard !title.isEmpty else { return .none }
        let clean = cleanTitle(title)

        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: clean),
            .init(name: "album_name", value: np.album ?? ""),
            .init(name: "duration", value: String(Int((np.duration ?? 0).rounded()))),
        ]
        if let t: LrclibTrack = await get(exact.url!), let l = lyrics(from: t) { return l }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [.init(name: "artist_name", value: artist), .init(name: "track_name", value: clean)]
        guard let results: [LrclibTrack] = await get(search.url!), !results.isEmpty else { return .none }
        // Prefer synced lyrics whose duration is close to the playing track.
        let dur = np.duration ?? 0
        let ranked = results.sorted {
            let a = ($0.syncedLyrics == nil ? 1000 : 0) + abs(($0.duration ?? 0) - dur)
            let b = ($1.syncedLyrics == nil ? 1000 : 0) + abs(($1.duration ?? 0) - dur)
            return a < b
        }
        for t in ranked { if let l = lyrics(from: t) { return l } }
        return .none
    }

    private static func lyrics(from t: LrclibTrack) -> Lyrics? {
        if t.instrumental == true { return .instrumental }
        if let s = t.syncedLyrics, !s.isEmpty {
            let lines = parseLRC(s)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let p = t.plainLyrics, !p.isEmpty {
            return .plain(p.components(separatedBy: "\n").filter { !$0.isEmpty })
        }
        return nil
    }

    private static func get<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("SpotifastLyrics (https://github.com/kshitijsriv/SpotifastLyrics)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// "Song (Remastered 2011) - Live" -> "Song"
    static func cleanTitle(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(remaster|live|version|edit|mono|stereo|mix|deluxe|feat)[^\)\]]*[\)\]]"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+-\s+.*(remaster|live|version|edit|mono|stereo|mix).*$"#,
                                   with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func parseLRC(_ s: String) -> [LyricLine] {
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [LyricLine] = []
        for raw in s.components(separatedBy: "\n") {
            let ns = raw as NSString
            let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let lastMatch = matches.last else { continue }
            let text = ns.substring(from: lastMatch.range.location + lastMatch.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(time: min * 60 + sec, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let watcher = NowPlayingWatcher()
    private var now: NowPlaying?
    private var lyrics: Lyrics = .none
    private var lyricsKey = ""
    private var fetchTask: Task<Void, Never>?
    private var timer: Timer?

    private let defaults = UserDefaults.standard
    private var showLyrics: Bool {
        get { defaults.object(forKey: "showLyrics") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLyrics"); refresh() }
    }
    private var spotifastOnly: Bool {
        get { defaults.object(forKey: "spotifastOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "spotifastOnly"); refresh() }
    }
    private var maxChars: Int {
        get { defaults.object(forKey: "maxChars") as? Int ?? 60 }
        set { defaults.set(newValue, forKey: "maxChars"); refresh() }
    }
    /// Seconds to shift lyrics; positive shows lines earlier.
    private var offset: Double {
        get { defaults.double(forKey: "offset") }
        set { defaults.set(newValue, forKey: "offset"); refresh() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setTitle("♪")

        watcher.onChange = { [weak self] np in self?.update(np) }
        watcher.start()

        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func applicationWillTerminate(_ n: Notification) { watcher.stop() }

    private var relevant: NowPlaying? {
        guard let np = now, np.playing else { return nil }
        if spotifastOnly && np.app != "rocks.spotifast.Spotifast" { return nil }
        return np
    }

    private func update(_ np: NowPlaying) {
        now = np
        guard let r = relevant, r.trackKey != lyricsKey else { refresh(); return }
        lyricsKey = r.trackKey
        lyrics = .none
        fetchTask?.cancel()
        fetchTask = Task { @MainActor [weak self] in
            let l = await LyricsFetcher.fetch(r)
            guard let self, !Task.isCancelled, self.lyricsKey == r.trackKey else { return }
            self.lyrics = l
            self.refresh()
        }
        refresh()
    }

    private func currentLine() -> String? {
        guard let np = relevant else { return nil }
        if case .synced(let lines) = lyrics {
            let pos = np.position + offset
            guard let line = lines.last(where: { $0.time <= pos }) else { return "♪" }
            return line.text.isEmpty ? "♪" : line.text
        }
        return nil
    }

    private func refresh() {
        guard showLyrics, let np = relevant else { setTitle("♪"); return }
        if let line = currentLine() {
            setTitle(line)
        } else {
            // No synced lyrics: fall back to the track name.
            setTitle("\(np.title ?? "") — \(np.artist ?? "")")
        }
    }

    private func setTitle(_ s: String) {
        let t = s.count > maxChars ? String(s.prefix(maxChars - 1)) + "…" : s
        if statusItem.button?.title != t { statusItem.button?.title = t }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let np = relevant {
            let header = NSMenuItem(title: "\(np.title ?? "") — \(np.artist ?? "")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let status: String
            switch lyrics {
            case .synced: status = "Synced lyrics from LRCLIB"
            case .plain: status = "Only unsynced lyrics found"
            case .instrumental: status = "Instrumental"
            case .none: status = "No lyrics found"
            }
            let s = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
            if let lyricsMenu = buildLyricsMenu(np) {
                let item = NSMenuItem(title: "Lyrics", action: nil, keyEquivalent: "")
                item.submenu = lyricsMenu
                menu.addItem(item)
            }
        } else {
            let i = NSMenuItem(title: "Nothing playing in Spotifast", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())

        add(menu, "Show Lyrics in Menu Bar", #selector(toggleShow), on: showLyrics, key: "l")
        add(menu, "Only Follow Spotifast", #selector(toggleSpotifastOnly), on: spotifastOnly)

        let width = NSMenuItem(title: "Max Width", action: nil, keyEquivalent: "")
        let wm = NSMenu()
        for n in [30, 45, 60, 80, 100] {
            let i = NSMenuItem(title: "\(n) characters", action: #selector(setWidth(_:)), keyEquivalent: "")
            i.target = self; i.tag = n; i.state = n == maxChars ? .on : .off
            wm.addItem(i)
        }
        width.submenu = wm
        menu.addItem(width)

        let off = NSMenuItem(title: String(format: "Timing Offset: %+.1fs", offset), action: nil, keyEquivalent: "")
        let om = NSMenu()
        add(om, "Earlier (+0.5s)", #selector(offsetEarlier), key: "]")
        add(om, "Later (−0.5s)", #selector(offsetLater), key: "[")
        add(om, "Reset", #selector(offsetReset))
        off.submenu = om
        menu.addItem(off)

        add(menu, "Refetch Lyrics", #selector(refetch), key: "r")
        menu.addItem(.separator())
        add(menu, "Launch at Login", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        add(menu, "Quit", #selector(quit), key: "q")
    }

    private func buildLyricsMenu(_ np: NowPlaying) -> NSMenu? {
        let m = NSMenu()
        switch lyrics {
        case .synced(let lines):
            let pos = np.position + offset
            let cur = lines.lastIndex(where: { $0.time <= pos })
            for (i, l) in lines.enumerated() where !l.text.isEmpty {
                let item = NSMenuItem(title: l.text, action: nil, keyEquivalent: "")
                item.state = i == cur ? .on : .off
                m.addItem(item)
            }
        case .plain(let lines):
            for l in lines { m.addItem(NSMenuItem(title: l, action: nil, keyEquivalent: "")) }
        default:
            return nil
        }
        return m
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        if let on { i.state = on ? .on : .off }
        menu.addItem(i)
        return i
    }

    @objc private func toggleShow() { showLyrics.toggle() }
    @objc private func toggleSpotifastOnly() { spotifastOnly.toggle(); lyricsKey = ""; if let n = now { update(n) } }
    @objc private func setWidth(_ s: NSMenuItem) { maxChars = s.tag }
    @objc private func offsetEarlier() { offset += 0.5 }
    @objc private func offsetLater() { offset -= 0.5 }
    @objc private func offsetReset() { offset = 0 }
    @objc private func refetch() { lyricsKey = ""; if let n = now { update(n) } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
