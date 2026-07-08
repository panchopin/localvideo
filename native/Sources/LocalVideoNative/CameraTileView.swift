import AppKit

/// Coordinates tile interaction gestures (drag-to-swap, double-click-to-enlarge)
/// with whatever owns the grid. Implemented by `GridContainerView`.
protocol CameraTileInteractionDelegate: AnyObject {
    func tileRequestedSoloToggle(_ tile: CameraTileView)
    func tileBeganDrag(_ tile: CameraTileView, at pointInWindow: NSPoint)
    func tileDraggedTo(pointInWindow point: NSPoint)
    func tileEndedDrag(at pointInWindow: NSPoint)
}

/// A single grid cell: the native video layer, a bottom-left status dot + name
/// overlay, and a bottom-right reconnect ("kick") button that appears on hover.
/// Also the source of the drag-to-swap and double-click-to-enlarge gestures.
final class CameraTileView: NSView {

    /// Stable identity of the camera shown here (used for solo bookkeeping).
    let cameraId: UUID
    let video = VideoLayerView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    /// The camera name without any zoom suffix (the label may show "Name  2.4×").
    private var baseName: String = ""
    private let statusDot = NSView()
    private let kickButton = NSButton()
    private var status: StreamStatus = .connecting
    private var hoverArea: NSTrackingArea?

    /// Receives gesture callbacks (set by the grid).
    weak var interactionDelegate: CameraTileInteractionDelegate?
    /// When true, hovering does not reveal the kick button (used during a drag so
    /// the button doesn't flash on tiles the ghost passes over).
    var hoverSuppressed = false

    // Drag-to-swap gesture state.
    private var mouseDownPoint: NSPoint?
    private var dragging = false
    private let dragThreshold: CGFloat = 6

    // Zoom-in-place gesture state.
    /// Last drag location (window coords) while panning a zoomed tile.
    private var lastPanPoint: NSPoint?
    /// Scroll-wheel points → zoom factor sensitivity.
    private let scrollZoomK: CGFloat = 0.01

    /// Invoked when the user clicks the reconnect button.
    var onKick: (() -> Void)?

    /// The displayed camera name (used to build the drag ghost). Excludes the zoom suffix.
    var cameraName: String { baseName }

    init(id: UUID, name: String) {
        self.cameraId = id
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        layer = root

        video.autoresizingMask = [.width, .height]
        video.onZoomChanged = { [weak self] in self?.updateZoomIndicator() }
        addSubview(video)

        statusDot.wantsLayer = true
        let dotLayer = CALayer()
        dotLayer.cornerRadius = 4
        dotLayer.backgroundColor = status.color.cgColor
        statusDot.layer = dotLayer
        addSubview(statusDot)

        baseName = name
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

    // MARK: - Mouse routing
    //
    // The video layer fills the whole tile, so route mouse events to the tile
    // itself (for drag / double-click) while still letting the visible kick
    // button receive clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        let local = convert(point, from: sv)
        guard bounds.contains(local) else { return nil }
        if !kickButton.isHidden, kickButton.frame.contains(local) {
            return kickButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double-click backs out the current close-up: reset zoom if zoomed,
            // otherwise toggle solo/enlarge. Cancel any armed drag/pan.
            mouseDownPoint = nil
            lastPanPoint = nil
            dragging = false
            if video.isZoomed {
                video.resetZoom()
            } else {
                interactionDelegate?.tileRequestedSoloToggle(self)
            }
            return
        }
        mouseDownPoint = event.locationInWindow
        lastPanPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        // When zoomed, a drag pans the picture (grab-and-move) instead of arming a
        // drag-to-swap. Window coords share the view's bottom-left y, so deltas map 1:1.
        if video.isZoomed {
            guard let last = lastPanPoint else { lastPanPoint = event.locationInWindow; return }
            let p = event.locationInWindow
            video.panBy(dxInView: p.x - last.x, dyInView: p.y - last.y)
            lastPanPoint = p
            return
        }
        guard let start = mouseDownPoint else { return }
        let p = event.locationInWindow
        if !dragging {
            let dx = p.x - start.x, dy = p.y - start.y
            if (dx * dx + dy * dy) >= dragThreshold * dragThreshold {
                dragging = true
                interactionDelegate?.tileBeganDrag(self, at: p)
            }
        } else {
            interactionDelegate?.tileDraggedTo(pointInWindow: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            interactionDelegate?.tileEndedDrag(at: event.locationInWindow)
        }
        mouseDownPoint = nil
        lastPanPoint = nil
        dragging = false
    }

    // MARK: - Zoom in place (pinch / scroll)

    /// Trackpad pinch → zoom about the gesture point.
    override func magnify(with event: NSEvent) {
        let p = video.convert(event.locationInWindow, from: nil)
        video.applyZoom(scaleDelta: 1 + event.magnification, aroundPointInView: p)
    }

    /// Scroll wheel. Horizontal scroll or ⇧+scroll → zoom about the pointer; a plain
    /// scroll pans the picture when zoomed (otherwise passed through).
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let zoomGesture = event.modifierFlags.contains(.shift) || abs(dx) > abs(dy)
        if zoomGesture {
            // Dominant-axis delta drives the zoom; clamp per event so a fast flick
            // can't slam across the whole range at once.
            let d = abs(dx) > abs(dy) ? dx : dy
            let factor = 1 + max(-0.3, min(0.3, d * scrollZoomK))
            let p = video.convert(event.locationInWindow, from: nil)
            video.applyZoom(scaleDelta: factor, aroundPointInView: p)
        } else if video.isZoomed {
            // Two-finger / wheel pan: the crop window follows the scroll direction,
            // i.e. the content moves opposite the scroll.
            video.panBy(dxInView: -dx, dyInView: dy)
        } else {
            super.scrollWheel(with: event)
        }
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

    override func mouseEntered(with event: NSEvent) {
        if !hoverSuppressed { kickButton.isHidden = false }
    }
    override func mouseExited(with event: NSEvent) { kickButton.isHidden = true }

    @objc private func kickTapped() { onKick?() }

    // MARK: - Drag visuals (driven by the grid)

    /// Force-hide the kick button (used when a drag starts).
    func hideKick() { kickButton.isHidden = true }

    /// Toggle the accent drop-target highlight border.
    func setDropHighlight(_ on: Bool) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = on ? 3 : 0
    }

    // MARK: - Updates

    func updateName(_ name: String) {
        baseName = name
        updateZoomIndicator()
    }

    /// Reflect the current zoom factor as a suffix on the name label ("Front Door  2.4×");
    /// shows just the name at exactly 1×.
    private func updateZoomIndicator() {
        nameLabel.stringValue = video.isZoomed
            ? String(format: "%@  %.1f×", baseName, video.zoomScale)
            : baseName
        needsLayout = true
    }

    func setStatus(_ newStatus: StreamStatus) {
        guard newStatus != status else { return }
        status = newStatus
        statusDot.layer?.backgroundColor = newStatus.color.cgColor
    }
}
