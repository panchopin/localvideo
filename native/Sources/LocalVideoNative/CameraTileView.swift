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
    /// Optional diagnostic counters appended to the label (see `setDebugStats`).
    private var debugSuffix: String?
    private let statusDot = NSView()
    private let kickButton = NSButton()
    /// Enlarge/restore toggle (same effect as double-click). Icon flips between
    /// 4-arrows-outward (expand) and 4-arrows-inward (retract) with solo state.
    private let expandButton = NSButton()
    private var isSolo = false
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

        expandButton.isHidden = true
        expandButton.bezelStyle = .circular
        expandButton.imagePosition = .imageOnly
        expandButton.image = CameraTileView.fourArrowImage(outward: true)
        expandButton.toolTip = "Enlarge (double-click)"
        expandButton.target = self
        expandButton.action = #selector(expandTapped)
        addSubview(expandButton)
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

        // Hover controls: reconnect in the bottom-right corner, enlarge/restore to
        // its left (AppKit origin is bottom-left).
        let btn: CGFloat = 26
        let gap: CGFloat = 6
        kickButton.frame = NSRect(x: bounds.width - btn - 6, y: 6, width: btn, height: btn)
        expandButton.frame = NSRect(x: bounds.width - btn * 2 - gap - 6, y: 6, width: btn, height: btn)
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
        if !expandButton.isHidden, expandButton.frame.contains(local) {
            return expandButton
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
        if !hoverSuppressed { kickButton.isHidden = false; expandButton.isHidden = false }
    }
    override func mouseExited(with event: NSEvent) {
        kickButton.isHidden = true
        expandButton.isHidden = true
    }

    @objc private func kickTapped() { onKick?() }

    /// Enlarge/restore this tile — same effect as a double-click.
    @objc private func expandTapped() { interactionDelegate?.tileRequestedSoloToggle(self) }

    /// Reflect whether this tile is currently enlarged (solo): flips the button
    /// icon between expand (4 arrows out) and retract (4 arrows in).
    func setSolo(_ on: Bool) {
        guard isSolo != on else { return }
        isSolo = on
        expandButton.image = CameraTileView.fourArrowImage(outward: !on)
        expandButton.toolTip = on ? "Restore grid (double-click)" : "Enlarge (double-click)"
    }

    // MARK: - Drag visuals (driven by the grid)

    /// Force-hide the hover controls (used when a drag starts).
    func hideHoverControls() {
        kickButton.isHidden = true
        expandButton.isHidden = true
    }

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
    /// shows just the name at exactly 1×. A debug suffix (render counters) is appended
    /// when enabled.
    private func updateZoomIndicator() {
        var text = baseName
        if video.isZoomed { text += String(format: "  %.1f×", video.zoomScale) }
        if let debugSuffix { text += "  " + debugSuffix }
        nameLabel.stringValue = text
        needsLayout = true
    }

    /// Show live render counters next to the name (LOCALVIDEO_DEBUG_STATS=1). Pass nil
    /// to clear. Diagnostic only — nothing in the render path reads this.
    func setDebugStats(_ text: String?) {
        guard debugSuffix != text else { return }
        debugSuffix = text
        updateZoomIndicator()
    }

    func setStatus(_ newStatus: StreamStatus) {
        guard newStatus != status else { return }
        status = newStatus
        statusDot.layer?.backgroundColor = newStatus.color.cgColor
    }

    // MARK: - Expand/retract icon

    /// A four-arrow glyph drawn along the diagonals: arrows point out toward the
    /// corners (`outward` — expand) or in toward the center (retract). Rendered as
    /// a template image so the circular button tints it like a system control.
    /// (SF Symbols has a 4-arrows-out symbol but no matching 4-arrows-in one.)
    private static func fourArrowImage(outward: Bool, side: CGFloat = 16) -> NSImage {
        func unit(_ v: NSPoint) -> NSPoint {
            let m = (v.x * v.x + v.y * v.y).squareRoot()
            return m == 0 ? v : NSPoint(x: v.x / m, y: v.y / m)
        }
        func rot(_ v: NSPoint, _ deg: CGFloat) -> NSPoint {
            let r = deg * .pi / 180
            return NSPoint(x: v.x * cos(r) - v.y * sin(r), y: v.x * sin(r) + v.y * cos(r))
        }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()   // color ignored — template image uses alpha only

            let c = NSPoint(x: side / 2, y: side / 2)
            let pad: CGFloat = 2.5
            let gap: CGFloat = 3.4       // half-length of the empty center
            let head: CGFloat = 3.6      // arrowhead barb length
            let corners = [NSPoint(x: pad, y: pad), NSPoint(x: side - pad, y: pad),
                           NSPoint(x: pad, y: side - pad), NSPoint(x: side - pad, y: side - pad)]
            for corner in corners {
                let dOut = unit(NSPoint(x: corner.x - c.x, y: corner.y - c.y))   // center → corner
                let inner = NSPoint(x: c.x + dOut.x * gap, y: c.y + dOut.y * gap)
                path.move(to: inner); path.line(to: corner)                      // shaft
                let tip = outward ? corner : inner
                let pointDir = outward ? dOut : NSPoint(x: -dOut.x, y: -dOut.y)   // way the arrow points
                let back = NSPoint(x: -pointDir.x, y: -pointDir.y)
                for barb in [rot(back, 32), rot(back, -32)] {
                    path.move(to: tip)
                    path.line(to: NSPoint(x: tip.x + barb.x * head, y: tip.y + barb.y * head))
                }
            }
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
