import AppKit

/// A sheet listing RTSP endpoints found by NetworkScanner. The user selects the
/// ones to add; `onAdd` is called with the chosen rows. Presented as a sheet on
/// the Preferences panel.
final class DiscoverySheetController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private let results: [DiscoveredCamera]
    private let onAdd: ([DiscoveredCamera]) -> Void
    private let tableView = NSTableView()
    private let addButton = NSButton()

    init(results: [DiscoveredCamera], onAdd: @escaping ([DiscoveredCamera]) -> Void) {
        self.results = results
        self.onAdd = onAdd
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "Discovered Cameras"
        super.init(window: win)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let header = NSTextField(labelWithString: "Found \(results.count) unmapped RTSP source\(results.count == 1 ? "" : "s"). Select which to add:")
        header.frame = NSRect(x: 16, y: 306, width: 448, height: 18)
        content.addSubview(header)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("found"))
        column.width = 430
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 22
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 448, height: 242))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        content.addSubview(scroll)

        // Pre-select everything so a single "Add Selected" click adds all.
        tableView.selectRowIndexes(IndexSet(0..<results.count), byExtendingSelection: false)

        let cancel = NSButton()
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancel(_:))
        cancel.frame = NSRect(x: 256, y: 14, width: 100, height: 30)
        content.addSubview(cancel)

        addButton.title = "Add Selected"
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addSelected)
        addButton.frame = NSRect(x: 364, y: 14, width: 100, height: 30)
        content.addSubview(addButton)
    }

    private func describe(_ cam: DiscoveredCamera) -> String {
        let path = cam.path ?? "(path unknown — set after adding)"
        let auth = cam.needsAuth ? "   🔒 needs login" : ""
        return "\(cam.host):\(cam.port)    \(path)\(auth)"
    }

    @objc private func addSelected() {
        let chosen = tableView.selectedRowIndexes.map { results[$0] }
        endSheet()
        onAdd(chosen)
    }

    @objc private func cancel(_ sender: Any?) {
        endSheet()
    }

    private func endSheet() {
        if let win = window, let parent = win.sheetParent {
            parent.endSheet(win)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: describe(results[row]))
        label.frame = NSRect(x: 4, y: 2, width: (tableColumn?.width ?? 420) - 8, height: 18)
        label.autoresizingMask = [.width]
        label.lineBreakMode = .byTruncatingMiddle
        cell.addSubview(label)
        cell.textField = label
        return cell
    }
}
