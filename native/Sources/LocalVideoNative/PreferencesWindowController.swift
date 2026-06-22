import AppKit

/// Non-modal Preferences panel for managing cameras (add / edit / delete).
///
/// It floats over the live grid (`nonactivatingPanel`) so editing never steals
/// focus from or tears down healthy streams. All changes go through
/// `AppDelegate.applyCameras`, which diffs and only restarts cameras whose
/// connection details changed, then persists cameras.json.
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private weak var app: AppDelegate?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let userField = NSTextField()
    private let passField = NSSecureTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton()
    private let addButton = NSButton()
    private let deleteButton = NSButton()
    private let scanButton = NSButton()

    private var selectedCameraId: UUID?
    private var discoverySheet: DiscoverySheetController?

    init(app: AppDelegate) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Camera Preferences"
        super.init(window: panel)
        self.app = app
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        buildUI()
        reloadFromModel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - UI construction

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // ---- Left: camera list ----
        let listHeader = NSTextField(labelWithString: "Cameras")
        listHeader.font = .boldSystemFont(ofSize: 12)
        listHeader.frame = NSRect(x: 16, y: 372, width: 240, height: 16)
        content.addSubview(listHeader)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("camera"))
        column.width = 220
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true

        scrollView.frame = NSRect(x: 16, y: 52, width: 240, height: 312)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        content.addSubview(scrollView)

        configureButton(addButton, title: "+", action: #selector(addCamera))
        addButton.frame = NSRect(x: 16, y: 14, width: 30, height: 28)
        content.addSubview(addButton)

        configureButton(deleteButton, title: "−", action: #selector(deleteSelected))
        deleteButton.frame = NSRect(x: 50, y: 14, width: 30, height: 28)
        content.addSubview(deleteButton)

        configureButton(scanButton, title: "Scan Network…", action: #selector(scanNetwork))
        scanButton.frame = NSRect(x: 86, y: 14, width: 156, height: 28)
        content.addSubview(scanButton)

        // ---- Right: edit form ----
        let formHeader = NSTextField(labelWithString: "Edit Camera")
        formHeader.font = .boldSystemFont(ofSize: 12)
        formHeader.frame = NSRect(x: 272, y: 372, width: 332, height: 16)
        content.addSubview(formHeader)

        addLabel("Name", x: 272, y: 346, to: content)
        configureField(nameField, placeholder: "Camera name", x: 272, y: 322, to: content)

        addLabel("URL", x: 272, y: 296, to: content)
        configureField(urlField, placeholder: "rtsp://host/path", x: 272, y: 272, to: content)

        addLabel("Username", x: 272, y: 246, to: content)
        configureField(userField, placeholder: "Optional", x: 272, y: 222, to: content)

        addLabel("Password", x: 272, y: 196, to: content)
        configureField(passField, placeholder: "Optional", x: 272, y: 172, to: content)

        errorLabel.frame = NSRect(x: 272, y: 116, width: 332, height: 48)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.maximumNumberOfLines = 3
        errorLabel.lineBreakMode = .byWordWrapping
        content.addSubview(errorLabel)

        configureButton(saveButton, title: "Save", action: #selector(saveForm))
        saveButton.frame = NSRect(x: 504, y: 14, width: 100, height: 30)
        saveButton.keyEquivalent = "\r"
        content.addSubview(saveButton)
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    private func configureField(_ field: NSTextField, placeholder: String, x: CGFloat, y: CGFloat, to parent: NSView) {
        field.placeholderString = placeholder
        field.frame = NSRect(x: x, y: y, width: 332, height: 22)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        parent.addSubview(field)
    }

    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, to parent: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 332, height: 14)
        parent.addSubview(label)
    }

    // MARK: - Model sync

    /// Called by AppDelegate after the camera model changes.
    func reloadFromModel() {
        tableView.reloadData()
        if let id = selectedCameraId, let row = app?.cameras.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        populateForm()
        updateButtons()
    }

    /// Refresh just the status dot for one camera's row.
    func refreshStatus(for id: UUID) {
        guard let row = app?.cameras.firstIndex(where: { $0.id == id }) else { return }
        tableView.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    private func populateForm() {
        guard let id = selectedCameraId, let cam = app?.cameras.first(where: { $0.id == id }) else {
            nameField.stringValue = ""
            urlField.stringValue = ""
            userField.stringValue = ""
            passField.stringValue = ""
            setFormEnabled(false)
            errorLabel.stringValue = ""
            return
        }
        setFormEnabled(true)
        nameField.stringValue = cam.name
        urlField.stringValue = cam.url
        userField.stringValue = cam.username ?? ""
        passField.stringValue = cam.password ?? ""
        errorLabel.stringValue = ""
    }

    private func setFormEnabled(_ enabled: Bool) {
        [nameField, urlField, userField, passField].forEach { $0.isEnabled = enabled }
        saveButton.isEnabled = enabled
    }

    private func updateButtons() {
        addButton.isEnabled = (app?.cameras.count ?? 0) < maxCameras
        deleteButton.isEnabled = selectedCameraId != nil
    }

    // MARK: - Actions

    @objc private func addCamera() {
        guard var list = app?.cameras, list.count < maxCameras else { return }
        let newCam = CameraConfig(name: uniqueName("New Camera", in: list), url: "rtsp://")
        list.append(newCam)
        selectedCameraId = newCam.id
        app?.applyCameras(list)   // → reloadFromModel restores selection
        window?.makeFirstResponder(nameField)
    }

    @objc private func saveForm() {
        guard let id = selectedCameraId, var list = app?.cameras,
              let idx = list.firstIndex(where: { $0.id == id }) else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passField.stringValue

        if name.isEmpty {
            return showError("Name can’t be empty.")
        }
        if list.contains(where: { $0.id != id && $0.name == name }) {
            return showError("Another camera already uses that name.")
        }
        if !url.hasPrefix("rtsp://") || url.count <= 7 {
            return showError("URL must start with rtsp:// and include a host.")
        }
        if user.isEmpty != pass.isEmpty {
            return showError("Set both username and password, or neither.")
        }

        list[idx] = CameraConfig(
            id: id, name: name, url: url,
            username: user.isEmpty ? nil : user,
            password: pass.isEmpty ? nil : pass
        )
        showError("")
        app?.applyCameras(list)
    }

    @objc private func deleteSelected() {
        guard let id = selectedCameraId,
              let cam = app?.cameras.first(where: { $0.id == id }),
              let win = window else { return }

        let alert = NSAlert()
        alert.messageText = "Delete “\(cam.name)”?"
        alert.informativeText = "The camera will be removed and its stream stopped."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  var list = self.app?.cameras else { return }
            list.removeAll { $0.id == id }
            self.selectedCameraId = list.first?.id
            self.app?.applyCameras(list)
        }
    }

    // MARK: - Network discovery

    @objc private func scanNetwork() {
        scanButton.isEnabled = false
        scanButton.title = "Scanning…"
        let configured = Set((app?.cameras ?? []).compactMap { hostPort(from: $0.url) })

        NetworkScanner.scan(configured: configured, progress: { [weak self] done, total in
            self?.scanButton.title = "Scanning… \(Int(Double(done) / Double(total) * 100))%"
        }, completion: { [weak self] results in
            guard let self else { return }
            self.scanButton.isEnabled = true
            self.scanButton.title = "Scan Network…"
            self.presentResults(results)
        })
    }

    private func presentResults(_ results: [DiscoveredCamera]) {
        guard !results.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No new cameras found"
            alert.informativeText = "Nothing on the local network responded as an unmapped RTSP source."
            if let win = window { alert.beginSheetModal(for: win) }
            return
        }
        let sheet = DiscoverySheetController(results: results) { [weak self] chosen in
            self?.addDiscovered(chosen)
        }
        discoverySheet = sheet
        if let win = window, let sheetWin = sheet.window {
            win.beginSheet(sheetWin) { [weak self] _ in self?.discoverySheet = nil }
        }
    }

    private func addDiscovered(_ chosen: [DiscoveredCamera]) {
        guard var list = app?.cameras else { return }
        var lastId: UUID?
        for cam in chosen where list.count < maxCameras {
            let path = cam.path ?? "/"
            let url = "rtsp://\(cam.host):\(cam.port)\(path)"
            let octet = cam.host.split(separator: ".").last.map(String.init) ?? cam.host
            let config = CameraConfig(name: uniqueName("Camera \(octet)", in: list), url: url)
            list.append(config)
            lastId = config.id
        }
        if let id = lastId { selectedCameraId = id }
        app?.applyCameras(list)   // → reloadFromModel selects the new camera for finishing
    }

    /// Extract "host:port" from an RTSP URL (default port 554).
    private func hostPort(from urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return "\(host):\(url.port ?? 554)"
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
    }

    private func uniqueName(_ base: String, in list: [CameraConfig]) -> String {
        let names = Set(list.map { $0.name })
        if !names.contains(base) { return base }
        var i = 2
        while names.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }

    // MARK: - NSTableView data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        app?.cameras.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let cams = app?.cameras, row >= 0, row < cams.count else { return nil }
        let cam = cams[row]

        let cell = NSTableCellView()

        let dot = NSView(frame: NSRect(x: 4, y: 8, width: 8, height: 8))
        dot.wantsLayer = true
        let dotLayer = CALayer()
        dotLayer.cornerRadius = 4
        dotLayer.backgroundColor = (app?.statuses[cam.id]?.color ?? NSColor.systemGray).cgColor
        dot.layer = dotLayer
        cell.addSubview(dot)

        let label = NSTextField(labelWithString: cam.name)
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 18, y: 3, width: (tableColumn?.width ?? 200) - 22, height: 18)
        label.autoresizingMask = [.width]
        cell.addSubview(label)
        cell.textField = label

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if let cams = app?.cameras, row >= 0, row < cams.count {
            selectedCameraId = cams[row].id
        } else {
            selectedCameraId = nil
        }
        populateForm()
        updateButtons()
    }
}
