import AppKit
import AVFoundation
import Darwin  // POSIX signals for clean ffmpeg teardown on Ctrl-C / SIGTERM

// ===========================================================================
// LocalVideoNative — native low-latency multi-camera RTSP viewer.
//
// Per camera:  ffmpeg (RTSP demux only) → H264Parser → CMSampleBuffer
//              → AVSampleBufferDisplayLayer (VideoToolbox decode + GPU render)
//
// Usage:   swift run LocalVideoNative [path/to/cameras.json]
//
// Keyboard (main window): 1-6 set columns (manual), 0 = auto layout,
//                         F fullscreen, Q/Esc quit. Also in the menu bar.
// ===========================================================================

let maxCameras = 9

/// Auto column count for N cameras: nearly-square via ceil(sqrt(N)). A non-full
/// last row is centered by GridContainerView, so e.g. 3 → 2-over-1-centered.
func autoColumns(_ n: Int) -> Int {
    guard n > 0 else { return 1 }
    return max(1, Int(Double(n).squareRoot().rounded(.up)))
}

enum LayoutMode: Equatable {
    case auto
    case manual(Int)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var grid: GridContainerView!
    private var emptyLabel: NSTextField!
    private var keyMonitor: Any?

    private(set) var configPath: String = "cameras.json"
    private(set) var cameras: [CameraConfig] = []
    private(set) var statuses: [UUID: StreamStatus] = [:]
    private var tilesById: [UUID: CameraTileView] = [:]
    private var sources: [UUID: RTSPSource] = [:]

    // Stream-health tracking (all touched on the main thread).
    private var lastFrameAt: [UUID: Date] = [:]
    private var sourceStartedAt: [UUID: Date] = [:]
    private var lastKickAt: [UUID: Date] = [:]
    private var healthTimer: Timer?

    private let freshWindow: TimeInterval = 3    // frames within 3s → green
    private let staleWindow: TimeInterval = 8    // no frames 3–8s → yellow; >8s → red
    private let connectGrace: TimeInterval = 12  // allow this long for the first frame
    private let kickCooldown: TimeInterval = 15  // min gap between auto-reconnects

    private var layoutMode: LayoutMode = .auto
    private var prefsController: PreferencesWindowController?
    private var signalSources: [DispatchSourceSignal] = []

    private let configPathArg: String?

    init(configPathArg: String?) {
        self.configPathArg = configPathArg
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reap any ffmpeg orphaned by a prior crashed/force-quit session before
        // we spawn fresh ones — prevents cross-session accumulation (the cause of
        // runaway CPU from piled-up demuxers).
        reapOrphanedFFmpeg()
        installSignalHandlers()

        configPath = Config.resolveConfigPath(explicit: configPathArg)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalVideo — Native RTSP Viewer"
        window.center()
        window.backgroundColor = .black

        let content = window.contentView!

        grid = GridContainerView()
        grid.frame = content.bounds
        grid.autoresizingMask = [.width, .height]
        content.addSubview(grid)

        emptyLabel = NSTextField(labelWithString: "No cameras configured.\nPress ⌘, to add one.")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 18)
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)

        setupMenu()
        installKeyHandler()

        // Build tiles/sources from the loaded config (all treated as new).
        applyCameras(Array(Config.load(from: configPath).prefix(maxCameras)))

        // No cameras yet → open Preferences so the user isn't stuck.
        if cameras.isEmpty {
            openPreferences()
        }

        startHealthTimer()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        sources.values.forEach { $0.stop() }
        // The per-source SIGKILL fallback is async (1.5s) and won't fire before the
        // process exits, so sweep synchronously to guarantee no ffmpeg outlives us.
        reapOrphanedFFmpeg()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - ffmpeg lifecycle hardening (no orphaned demuxers)

    /// Force-kill any ffmpeg this app has spawned (matched by a credential-free
    /// argument signature). Used at launch to clear orphans from a prior crashed
    /// session, and on shutdown to catch any stalled straggler.
    private func reapOrphanedFFmpeg() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-KILL", "-f", RTSPSource.ffmpegSignature]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Catch Ctrl-C (SIGINT, common in `swift run`), SIGTERM and SIGHUP so we tear
    /// down ffmpeg children instead of dying and orphaning them. NSApplication does
    /// not handle these by default; a DispatchSource runs our handler safely on the
    /// main queue (signal handlers themselves must stay async-signal-safe).
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)  // suppress the default terminate; observe via the source
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.sources.values.forEach { $0.stop() }
                self?.reapOrphanedFFmpeg()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Camera model (diffed apply)

    /// Apply a new camera list: stop removed cameras, start added ones, and
    /// restart ONLY cameras whose connection details actually changed. Healthy
    /// unchanged streams are never touched. Persists to cameras.json.
    func applyCameras(_ newCameras: [CameraConfig]) {
        let capped = Array(newCameras.prefix(maxCameras))
        let oldById = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
        let newIds = Set(capped.map { $0.id })

        // Remove deleted cameras.
        for old in cameras where !newIds.contains(old.id) {
            sources[old.id]?.stop()
            sources[old.id] = nil
            tilesById[old.id]?.removeFromSuperview()
            tilesById[old.id] = nil
            statuses[old.id] = nil
        }

        // Add / update, building the tile order to match the new list.
        var orderedTiles: [CameraTileView] = []
        for cam in capped {
            if let old = oldById[cam.id], let tile = tilesById[cam.id] {
                if old.name != cam.name { tile.updateName(cam.name) }
                if old.resolvedURL != cam.resolvedURL {
                    sources[cam.id]?.stop()
                    startCamera(cam)
                }
                orderedTiles.append(tile)
            } else {
                let tile = CameraTileView(name: cam.name)
                tile.onKick = { [weak self] in self?.reconnect(id: cam.id) }
                tilesById[cam.id] = tile
                startCamera(cam)
                orderedTiles.append(tile)
            }
        }

        cameras = capped
        grid.setTiles(orderedTiles)
        updateLayout()
        updateEmptyState()
        persist()
        prefsController?.reloadFromModel()
    }

    private func makeSource(_ camera: CameraConfig) -> RTSPSource {
        let source = RTSPSource(url: camera.resolvedURL)
        let id = camera.id
        source.onSampleBuffer = { [weak self] sb in
            DispatchQueue.main.async {
                self?.lastFrameAt[id] = Date()   // freshness signal
                self?.tilesById[id]?.video.enqueue(sb)
            }
        }
        source.onStatus = { [weak self] status in
            // ffmpeg exited — fail fast and reconnect now (the health timer
            // separately catches silent stalls where ffmpeg stays alive).
            guard status == .failed else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.setStatus(.failed, for: id)
                if Date().timeIntervalSince(self.lastKickAt[id] ?? .distantPast) >= self.kickCooldown {
                    self.reconnect(id: id)
                }
            }
        }
        return source
    }

    /// Create + start a source for one camera and reset its health trackers.
    private func startCamera(_ cam: CameraConfig) {
        let source = makeSource(cam)
        sources[cam.id] = source
        sourceStartedAt[cam.id] = Date()
        lastFrameAt[cam.id] = nil
        source.start()
    }

    /// Force a fresh connection for one camera (manual kick button, or auto on stall).
    func reconnect(id: UUID) {
        guard let cam = cameras.first(where: { $0.id == id }) else { return }
        sources[id]?.stop()
        tilesById[id]?.video.flushDisplay()
        lastKickAt[id] = Date()
        setStatus(.connecting, for: id)
        startCamera(cam)
    }

    private func setStatus(_ status: StreamStatus, for id: UUID) {
        guard statuses[id] != status else { return }   // avoid 1 Hz churn
        statuses[id] = status
        tilesById[id]?.setStatus(status)
        prefsController?.refreshStatus(for: id)
    }

    // MARK: - Stream health (freshness → status + auto-reconnect)

    private func startHealthTimer() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    /// Derive each camera's status from how recently a frame arrived, and
    /// auto-kick a stalled stream (with a cooldown so we don't thrash).
    private func checkHealth() {
        let now = Date()
        for cam in cameras {
            let id = cam.id
            let status: StreamStatus
            if let last = lastFrameAt[id] {
                let age = now.timeIntervalSince(last)
                status = age <= freshWindow ? .streaming : (age <= staleWindow ? .connecting : .failed)
            } else {
                // No frame yet since (re)connect — grace period, then treat as failed.
                let waited = now.timeIntervalSince(sourceStartedAt[id] ?? now)
                status = waited <= connectGrace ? .connecting : .failed
            }
            setStatus(status, for: id)

            if status == .failed, now.timeIntervalSince(lastKickAt[id] ?? .distantPast) >= kickCooldown {
                reconnect(id: id)   // auto-reconnect stalled/dead stream
            }
        }
    }

    private func persist() {
        do {
            try Config.save(cameras, to: configPath)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save cameras.json"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateEmptyState() {
        let empty = cameras.isEmpty
        grid.isHidden = empty
        emptyLabel.isHidden = !empty
    }

    // MARK: - Layout

    private func updateLayout() {
        switch layoutMode {
        case .auto: grid.columns = autoColumns(cameras.count)
        case .manual(let n): grid.columns = n
        }
    }

    private func setLayoutMode(_ mode: LayoutMode) {
        layoutMode = mode
        updateLayout()
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LocalVideo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (enables Cut/Copy/Paste in the Preferences text fields)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let fs = viewMenu.addItem(withTitle: "Toggle Fullscreen", action: #selector(toggleFullScreenAction), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(.separator())

        let gridItem = NSMenuItem(title: "Grid Layout", action: nil, keyEquivalent: "")
        let gridMenu = NSMenu(title: "Grid Layout")
        gridItem.submenu = gridMenu
        let autoItem = NSMenuItem(title: "Auto", action: #selector(setAutoLayout), keyEquivalent: "0")
        autoItem.tag = 0
        gridMenu.addItem(autoItem)
        for i in 1...6 {
            let item = NSMenuItem(title: i == 1 ? "1 Column" : "\(i) Columns",
                                  action: #selector(setManualLayout(_:)), keyEquivalent: "\(i)")
            item.tag = i
            gridMenu.addItem(item)
        }
        viewMenu.addItem(gridItem)

        NSApp.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Reflect the current layout mode with a checkmark on the Grid submenu.
        if menuItem.action == #selector(setAutoLayout) {
            menuItem.state = (layoutMode == .auto) ? .on : .off
        } else if menuItem.action == #selector(setManualLayout(_:)) {
            menuItem.state = (layoutMode == .manual(menuItem.tag)) ? .on : .off
        }
        return true
    }

    @objc private func openPreferences() {
        if prefsController == nil {
            prefsController = PreferencesWindowController(app: self)
        }
        prefsController?.showWindow(nil)
        prefsController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleFullScreenAction() {
        window.toggleFullScreen(nil)
    }

    @objc private func setAutoLayout() {
        setLayoutMode(.auto)
    }

    @objc private func setManualLayout(_ sender: NSMenuItem) {
        setLayoutMode(.manual(sender.tag))
    }

    // MARK: - Bare-key shortcuts (main window only)

    private func installKeyHandler() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only handle bare keys for the main window; let the Preferences
            // panel's text fields receive normal typing.
            guard event.window === self.window else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
                return event  // let ⌘/⌃ combos go to the menu
            }
            if event.keyCode == 53 {  // Escape
                NSApp.terminate(nil)
                return nil
            }
            guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            switch ch {
            case "q":
                NSApp.terminate(nil); return nil
            case "f":
                self.window.toggleFullScreen(nil); return nil
            case "0":
                self.setLayoutMode(.auto); return nil
            case "1"..."6":
                if let n = ch.wholeNumberValue { self.setLayoutMode(.manual(n)) }
                return nil
            default:
                return event
            }
        }
    }
}

// --- CLI: optional cameras.json path ---
let configArg = Array(CommandLine.arguments.dropFirst()).first

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(configPathArg: configArg)
app.delegate = delegate
app.run()
