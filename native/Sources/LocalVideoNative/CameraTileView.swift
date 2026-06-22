import AppKit

/// A single grid cell: the native video layer plus a bottom-left overlay with a
/// status dot and the camera name.
final class CameraTileView: NSView {

    let video = VideoLayerView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private var status: StreamStatus = .connecting

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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        video.frame = bounds

        let pad: CGFloat = 4
        let dotSize: CGFloat = 8
        nameLabel.sizeToFit()
        let labelH = nameLabel.frame.height + 4
        // AppKit origin is bottom-left → keep the overlay in the bottom corner.
        statusDot.frame = NSRect(x: pad, y: pad + (labelH - dotSize) / 2, width: dotSize, height: dotSize)

        let labelX = pad + dotSize + 4
        let maxW = bounds.width - labelX - pad
        let w = min(nameLabel.frame.width + 10, max(0, maxW))
        nameLabel.frame = NSRect(x: labelX, y: pad, width: w, height: labelH)
    }

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
