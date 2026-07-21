import AppKit
import AVFoundation

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

    // Recording. A camera streams (has a source) when showVideoStream || recordVideo;
    // a recorder is attached only while recordVideo is on. See docs/RECORDING_SPEC.md.
    private(set) var recordingSettings: RecordingSettings = .default
    private var recordingStore = RecordingStore(settings: .default)
    private var recorders: [UUID: CameraRecorder] = [:]
    private var retentionTimer: Timer?

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

    // Solo (double-click enlarge): which camera is enlarged, and the layout to
    // restore when solo exits. Transient view state — never persisted.
    private var soloedId: UUID?
    private var preSoloLayout: LayoutMode?

    // Update-check state (main thread only). Guards against overlapping checks.
    private var updateCheckInFlight = false

    private let configPathArg: String?

    init(configPathArg: String?) {
        self.configPathArg = configPathArg
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        grid.onReorder = { [weak self] from, to in self?.reorderCameras(from: from, to: to) }
        grid.onToggleSolo = { [weak self] tile in self?.toggleSolo(tile) }
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

        // Load global recording settings before building cameras (recorders attach
        // during applyCameras).
        recordingSettings = Config.loadRecording(from: configPath)
        recordingStore = RecordingStore(settings: recordingSettings)
        startRetentionTimer()

        // Build tiles/sources from the loaded config (all treated as new).
        applyCameras(Array(Config.load(from: configPath).prefix(maxCameras)))

        // No cameras yet → open Preferences so the user isn't stuck.
        if cameras.isEmpty {
            openPreferences()
        }

        startHealthTimer()
        NSApp.activate(ignoringOtherApps: true)

        // Silent update check a few seconds after launch: only surfaces UI if a
        // newer release exists. Skipped for non-bundle dev runs (`swift run`).
        if Bundle.main.bundlePath.hasSuffix(".app") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.checkForUpdates(userInitiated: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        healthTimer?.invalidate()
        retentionTimer?.invalidate()
        // In-process demux threads are interrupted and wound down here; nothing
        // outlives the app (no subprocess to orphan).
        sources.values.forEach { $0.stop() }
        // Finalise any in-progress recordings so the last segment is playable
        // (bounded wait so quit never hangs).
        let group = DispatchGroup()
        for rec in recorders.values { group.enter(); rec.stop { group.leave() } }
        recorders.removeAll()
        _ = group.wait(timeout: .now() + 2.0)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Camera model (diffed apply)

    /// Cameras that should stream in the grid right now (the rest stay configured
    /// but hidden). Source of the tile/stream/layout set.
    private var shownCameras: [CameraConfig] { cameras.filter { $0.showVideoStream } }

    /// Apply a new camera list: only cameras with `showVideoStream` get a tile +
    /// stream; the grid adapts to that subset. Streams are stopped for cameras that
    /// were deleted OR toggled hidden, started for ones added OR toggled shown, and
    /// restarted ONLY when connection details changed. Persists the FULL list.
    func applyCameras(_ newCameras: [CameraConfig]) {
        let capped = Array(newCameras.prefix(maxCameras))
        let oldById = Dictionary(uniqueKeysWithValues: cameras.map { ($0.id, $0) })
        // Tiles are shown cameras; streams also include record-only cameras.
        let shouldShow   = Set(capped.filter { $0.showVideoStream }.map { $0.id })
        let shouldStream = Set(capped.filter { $0.showVideoStream || $0.recordVideo }.map { $0.id })

        // Stop streams (+ their recorders) for cameras that should no longer stream —
        // covers deletion and both toggles going off. Keyed off `sources`.
        for id in Array(sources.keys) where !shouldStream.contains(id) {
            stopStream(id)
        }
        // Remove tiles for cameras that should no longer be shown (a hidden camera
        // may still stream for recording). Keyed off `tilesById`.
        for (id, tile) in tilesById where !shouldShow.contains(id) {
            tile.removeFromSuperview()
            tilesById[id] = nil
        }

        // If the enlarged camera is no longer shown (deleted or hidden), exit solo.
        if let s = soloedId, !shouldShow.contains(s) { exitSolo() }

        // Add / update streams, recorders, and tiles in list order.
        var orderedTiles: [CameraTileView] = []
        for cam in capped {
            let old = oldById[cam.id]
            // Stream + recorder (needed when shown OR recording).
            if cam.showVideoStream || cam.recordVideo {
                if sources[cam.id] == nil {
                    startCamera(cam)                                   // brand-new stream
                } else if let old, old.resolvedURL != cam.resolvedURL {
                    stopStream(cam.id)                                 // url changed → restart
                    startCamera(cam)
                } else {
                    reconcileRecorder(cam, old: old)                  // stream stays; toggle/rename recorder
                }
            }
            // Tile (shown cameras only).
            if cam.showVideoStream {
                if let tile = tilesById[cam.id] {
                    if old?.name != cam.name { tile.updateName(cam.name) }
                    orderedTiles.append(tile)
                } else {
                    let tile = CameraTileView(id: cam.id, name: cam.name)
                    tile.onKick = { [weak self] in self?.reconnect(id: cam.id) }
                    tilesById[cam.id] = tile
                    orderedTiles.append(tile)
                }
            }
        }

        cameras = capped
        grid.setTiles(orderedTiles)
        refreshSoloIndicators()
        updateLayout()
        updateEmptyState()
        persist()
        prefsController?.reloadFromModel()

        // Test seam: let a smoke test assert how many cameras are shown.
        if ProcessInfo.processInfo.environment["LOCALVIDEO_SMOKE"] == "1" {
            FileHandle.standardError.write("SHOWN_CAMERAS=\(shownCameras.count)\n".data(using: .utf8)!)
        }
    }

    // MARK: - Reorder (drag-to-swap) & solo (double-click enlarge)

    /// Swap two cameras' positions (from a tile drag). Pure reorder: no stream is
    /// stopped or restarted — tiles keep their live `RTSPSource`. Persisted so the
    /// order survives relaunch.
    private func reorderCameras(from: Int, to: Int) {
        // from/to are indices into the SHOWN tiles (grid.tiles). Map them to the
        // full `cameras` array by identity so interspersed hidden cameras keep
        // their slots, then swap.
        let tiles = grid.tiles
        guard tiles.indices.contains(from), tiles.indices.contains(to), from != to else { return }
        let fromId = tiles[from].cameraId, toId = tiles[to].cameraId
        guard let fi = cameras.firstIndex(where: { $0.id == fromId }),
              let ti = cameras.firstIndex(where: { $0.id == toId }) else { return }
        cameras.swapAt(fi, ti)
        grid.setTiles(shownCameras.compactMap { tilesById[$0.id] })   // reorder; no source touched
        updateLayout()
        persist()
        prefsController?.reloadFromModel()
    }

    /// Toggle enlarge for a tile: enter solo (remembering the current layout) or,
    /// if already solo, exit back to that layout.
    private func toggleSolo(_ tile: CameraTileView) {
        if soloedId != nil {
            exitSolo()
        } else {
            preSoloLayout = layoutMode
            soloedId = tile.cameraId
            grid.setSolo(tile)
        }
        refreshSoloIndicators()
    }

    private func exitSolo() {
        guard soloedId != nil else { return }
        soloedId = nil
        grid.setSolo(nil)
        if let restore = preSoloLayout {
            layoutMode = restore
            updateLayout()
        }
        preSoloLayout = nil
        refreshSoloIndicators()
    }

    /// Sync each tile's expand/retract button icon to the current solo state.
    private func refreshSoloIndicators() {
        for tile in grid.tiles { tile.setSolo(tile.cameraId == soloedId) }
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

    /// Create + start a source for one camera and reset its health trackers. Attaches
    /// a recorder first (before the demux thread starts) when the camera records.
    private func startCamera(_ cam: CameraConfig) {
        let source = makeSource(cam)
        if cam.recordVideo {
            let rec = CameraRecorder(cameraName: cam.name, store: recordingStore)
            recorders[cam.id] = rec
            source.recorder = rec
        }
        sources[cam.id] = source
        sourceStartedAt[cam.id] = Date()
        lastFrameAt[cam.id] = nil
        source.start()
    }

    /// Fully stop a camera's stream + recorder and clear its health trackers.
    private func stopStream(_ id: UUID) {
        sources[id]?.stop()
        sources[id] = nil
        recorders[id]?.stop()      // finalises the in-progress segment
        recorders[id] = nil
        statuses[id] = nil
        lastFrameAt[id] = nil
        sourceStartedAt[id] = nil
        lastKickAt[id] = nil
    }

    /// For a camera whose stream stays up, bring its recorder into line with the
    /// config: start one when recording turns on, stop one when it turns off, and
    /// restart it on rename (so new segments use the new camera name/folder).
    private func reconcileRecorder(_ cam: CameraConfig, old: CameraConfig?) {
        let existing = recorders[cam.id]
        if cam.recordVideo {
            if existing == nil || old?.name != cam.name {
                existing?.stop()
                let rec = CameraRecorder(cameraName: cam.name, store: recordingStore)
                recorders[cam.id] = rec
                sources[cam.id]?.recorder = rec
            }
        } else if let existing {
            sources[cam.id]?.recorder = nil
            existing.stop()
            recorders[cam.id] = nil
        }
    }

    /// Force a fresh connection for one camera (manual kick button, or auto on stall).
    func reconnect(id: UUID) {
        // Never resurrect a hidden camera (guards against a demux-thread callback
        // arriving right after stop() during a toggle-off).
        guard let cam = cameras.first(where: { $0.id == id }),
              cam.showVideoStream || cam.recordVideo else { return }
        sources[id]?.stop()
        recorders[id]?.stop()          // finalise the segment; startCamera makes a fresh one
        recorders[id] = nil
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

    // MARK: - Recording retention

    /// Prune expired recordings shortly after launch, then every 10 minutes.
    private func startRetentionTimer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.pruneRecordings() }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            self?.pruneRecordings()
        }
    }

    /// Delete recordings older than the retention window (off the main thread). The
    /// active-segment paths are just belt-and-suspenders — freshly written files are
    /// hours from the cutoff, so they're never eligible anyway.
    private func pruneRecordings() {
        let active = Set(recorders.values.compactMap { $0.activeFinalPath })
        let store = recordingStore
        DispatchQueue.global(qos: .utility).async { store.prune(activePaths: active) }
    }

    /// Apply changed global recording settings (folder / retention / segment length):
    /// update the store, restart any active recorders so the new folder + segment
    /// length take effect on their next file, persist. Called from Preferences.
    func updateRecordingSettings(_ new: RecordingSettings) {
        guard new != recordingSettings else { return }
        recordingSettings = new
        recordingStore.updateSettings(new)
        for id in Array(recorders.keys) {
            recorders[id]?.stop()
            recorders[id] = nil
            if let cam = cameras.first(where: { $0.id == id }), let src = sources[id] {
                let rec = CameraRecorder(cameraName: cam.name, store: recordingStore)
                recorders[id] = rec
                src.recorder = rec
            }
        }
        persist()
    }

    /// Derive each camera's status from how recently a frame arrived, and
    /// auto-kick a stalled stream (with a cooldown so we don't thrash).
    private func checkHealth() {
        let now = Date()
        // Only cameras with a live source (shown). Hidden cameras have none, so
        // they are never health-checked or auto-reconnected. Snapshot the keys to
        // avoid mutating `sources` mid-iteration (reconnect replaces entries).
        for id in Array(sources.keys) {
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
            try Config.save(cameras, recording: recordingSettings, to: configPath)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save cameras.json"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateEmptyState() {
        // Empty when nothing is shown — either no cameras at all, or all hidden.
        let noneShown = shownCameras.isEmpty
        grid.isHidden = noneShown
        emptyLabel.isHidden = !noneShown
        if cameras.isEmpty {
            emptyLabel.stringValue = "No cameras configured.\nPress ⌘, to add one."
        } else if noneShown {
            emptyLabel.stringValue = "All cameras are hidden.\nEnable one in Preferences (⌘,)."
        }
    }

    // MARK: - Layout

    private func updateLayout() {
        switch layoutMode {
        case .auto: grid.columns = autoColumns(shownCameras.count)
        case .manual(let n): grid.columns = n
        }
    }

    private func setLayoutMode(_ mode: LayoutMode) {
        // An explicit layout command (0 / 1–6) exits solo and applies the
        // requested layout (rather than restoring the pre-solo one).
        if soloedId != nil {
            soloedId = nil
            preSoloLayout = nil
            grid.setSolo(nil)
            refreshSoloIndicators()
        }
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
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdatesMenu), keyEquivalent: "")
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

    // MARK: - Updates (consults the public GitHub Releases)

    @objc private func checkForUpdatesMenu() { checkForUpdates(userInitiated: true) }

    /// Ask GitHub for the latest release. A user-initiated check reports "up to
    /// date" and errors; the silent launch check only surfaces UI when newer.
    private func checkForUpdates(userInitiated: Bool) {
        guard !updateCheckInFlight else { return }
        updateCheckInFlight = true
        Updater.fetchLatestRelease { [weak self] result in
            guard let self else { return }
            self.updateCheckInFlight = false
            switch result {
            case .success(let release):
                if Updater.isNewer(release.version, than: Updater.currentVersion) {
                    self.promptForUpdate(release)
                } else if userInitiated {
                    self.infoAlert("You're up to date",
                                   "LocalVideo \(Updater.currentVersion) is the latest version.")
                }
            case .failure(let error):
                if userInitiated {
                    self.infoAlert("Couldn't check for updates", error.localizedDescription)
                }   // silent launch checks fail quietly
            }
        }
    }

    private func promptForUpdate(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "Update available: LocalVideo \(release.version)"
        var info = "You have \(Updater.currentVersion). Update now? The app will restart."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let clipped = notes.count > 600 ? String(notes.prefix(600)) + "…" : notes
            info += "\n\nWhat's new:\n" + clipped
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            performUpdate(release)
        }
    }

    private func performUpdate(_ release: Updater.Release) {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            openReleasePage(release, reason: Updater.UpdaterError.notABundle.localizedDescription)
            return
        }
        let panel = UpdateProgressPanel(over: window, version: release.version)
        panel.show()
        Updater.download(release, progress: { p in
            panel.setProgress(p)
        }, completion: { [weak self] result in
            switch result {
            case .success(let zipURL):
                panel.setInstalling()
                do {
                    try Updater.installAndRelaunch(zipAt: zipURL)   // quits the app on success
                } catch {
                    panel.close()
                    self?.openReleasePage(release, reason: error.localizedDescription)
                }
            case .failure(let error):
                panel.close()
                self?.openReleasePage(release, reason: error.localizedDescription)
            }
        })
    }

    /// Fallback when the in-app install can't proceed: offer the release page so the
    /// user can grab the zip by hand.
    private func openReleasePage(_ release: Updater.Release, reason: String) {
        let alert = NSAlert()
        alert.messageText = "Automatic update didn't complete"
        alert.informativeText = reason + "\n\nYou can download it manually from the release page."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func infoAlert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
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
                if self.grid.isDragging {   // cancel an in-progress drag instead of quitting
                    self.grid.cancelActiveDrag()
                    return nil
                }
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

/// A minimal sheet shown over the main window during an update download/install:
/// a title line and a determinate progress bar (indeterminate while installing).
final class UpdateProgressPanel {
    private let parent: NSWindow
    private let sheet: NSWindow
    private let bar = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    init(over parent: NSWindow, version: String) {
        self.parent = parent
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                         styleMask: [.titled], backing: .buffered, defer: false)
        let content = sheet.contentView!

        label.stringValue = "Downloading LocalVideo \(version)…"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 20, y: 54, width: 340, height: 20)
        content.addSubview(label)

        bar.frame = NSRect(x: 20, y: 26, width: 340, height: 18)
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.style = .bar
        content.addSubview(bar)
    }

    func show() { parent.beginSheet(sheet, completionHandler: nil) }
    func setProgress(_ p: Double) { bar.isIndeterminate = false; bar.doubleValue = p }
    func setInstalling() {
        label.stringValue = "Installing update…"
        bar.isIndeterminate = true
        bar.startAnimation(nil)
    }
    func close() { parent.endSheet(sheet) }
}

/// Hidden self-test: run the record path (H264Parser → CameraRecorder) over an
/// Annex-B H.264 file, no GUI/network — deterministic regression coverage for
/// recording. Usage:  LocalVideoNative --selftest-record <in.h264> <outDir> <segSeconds>
func runRecordSelfTest(_ args: [String]) -> Never {
    guard args.count >= 3 else {
        FileHandle.standardError.write("usage: --selftest-record <in.h264> <outDir> <segSeconds>\n".data(using: .utf8)!)
        exit(2)
    }
    let inPath = args[0], outDir = args[1]
    let seg = Int(args[2]) ?? 60
    // Optional 4th arg: spread the feed over this many seconds to mimic a real-time
    // stream (host-clock PTS ⇒ segment length & file duration track wall-clock).
    let paceSeconds = args.count >= 4 ? (Double(args[3]) ?? 0) : 0
    guard let data = FileManager.default.contents(atPath: inPath) else {
        FileHandle.standardError.write("cannot read \(inPath)\n".data(using: .utf8)!); exit(2)
    }
    let store = RecordingStore(settings: RecordingSettings(directory: outDir, retentionHours: 48, segmentSeconds: seg))
    let recorder = CameraRecorder(cameraName: "SelfTest", store: store)
    let parser = H264Parser()
    parser.onSampleBuffer = { sb in recorder.queue.async { recorder.append(sb) } }

    // Feed in small chunks to mimic streamed reads; pace them if requested.
    let chunk = paceSeconds > 0 ? 4 * 1024 : 16 * 1024
    let chunks = (data.count + chunk - 1) / chunk
    let perChunkSleep = paceSeconds > 0 ? paceSeconds / Double(max(1, chunks)) : 0
    var offset = 0
    while offset < data.count {
        let end = min(offset + chunk, data.count)
        parser.append(data.subdata(in: offset..<end))
        offset = end
        if perChunkSleep > 0 { Thread.sleep(forTimeInterval: perChunkSleep) }
    }
    let done = DispatchSemaphore(value: 0)
    recorder.stop { done.signal() }
    _ = done.wait(timeout: .now() + 15)
    Thread.sleep(forTimeInterval: 1.5)   // let earlier segments' async finalize/rename settle
    FileHandle.standardError.write("selftest-record: done\n".data(using: .utf8)!)
    exit(0)
}

// --- CLI: optional cameras.json path ---
if let i = CommandLine.arguments.firstIndex(of: "--selftest-record") {
    runRecordSelfTest(Array(CommandLine.arguments.dropFirst(i + 1)))
}
let configArg = Array(CommandLine.arguments.dropFirst()).first

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(configPathArg: configArg)
app.delegate = delegate
app.run()
