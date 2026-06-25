import AppKit

/// A single grid cell: the native video layer, a bottom-left status dot + name
/// overlay, and a bottom-right reconnect ("kick") button that appears on hover.
final class CameraTileView: NSView {

    let video = VideoLayerView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let kickButton = NSButton()
    private var status: StreamStatus = .connecting
    private var hoverArea: NSTrackingArea?

    /// Invoked when the user clicks the reconnect button.
    var onKick: (() -> Void)?

    init(name: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer = root

        video.autoresizingMask = [.width, .height]
        addSubview(video)

        statusDot.wantsLayer = true
        let dotLayer = CALayer()
        dotLayer.cornerRadius = 4
        dotLayer.backgroundColor = status.color.cgColor
        statusDot.layer = dotLayer
        addSubview(statusDot)

        nameLabel.stringValue = name
        nameLabel.textColor = .white
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.drawsBackground = true
        nameLabel.backgroundColor = NSColor(white: 0, alpha: 0.45)
        nameLabel.isBezeled = false
        nameLabel.isEditable = false
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        kickButton.isHidden = true
        kickButton.bezelStyle = .circular
        kickButton.imagePosition = .imageOnly
        kickButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reconnect")
        if kickButton.image == nil { kickButton.title = "⟳" }
        kickButton.toolTip = "Reconnect this camera"
        kickButton.target = self
        kickButton.action = #selector(kickTapped)
        addSubview(kickButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        video.frame = bounds

        let pad: CGFloat = 4
        let dotSize: CGFloat = 8
        nameLabel.sizeToFit()
        let labelH = nameLabel.frame.height + 4
        statusDot.frame = NSRect(x: pad, y: pad + (labelH - dotSize) / 2, width: dotSize, height: dotSize)

        let labelX = pad + dotSize + 4
        let labelW = min(nameLabel.frame.width + 10, max(0, bounds.width - labelX - pad))
        nameLabel.frame = NSRect(x: labelX, y: pad, width: labelW, height: labelH)

        // Reconnect button: bottom-right corner (AppKit origin is bottom-left).
        let btn: CGFloat = 26
        kickButton.frame = NSRect(x: bounds.width - btn - 6, y: 6, width: btn, height: btn)
    }

    // MARK: - Hover → show/hide the reconnect button

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { kickButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { kickButton.isHidden = true }

    @objc private func kickTapped() { onKick?() }

    // MARK: - Updates

    func updateName(_ name: String) {
        nameLabel.stringValue = name
        needsLayout = true
    }

    func setStatus(_ newStatus: StreamStatus) {
        guard newStatus != status else { return }
        status = newStatus
        statusDot.layer?.backgroundColor = newStatus.color.cgColor
    }
}
