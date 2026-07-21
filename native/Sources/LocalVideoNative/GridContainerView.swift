import AppKit

/// Arranges camera tiles in a grid with a configurable number of columns.
/// Also hosts two interactions: drag-to-swap (reorder) and double-click solo
/// (enlarge one tile to fill the grid). Neither disturbs the video pipeline —
/// layout just moves frames; solo only toggles `isHidden` on the other tiles.
final class GridContainerView: NSView, CameraTileInteractionDelegate {

    private(set) var tiles: [CameraTileView] = []
    private let spacing: CGFloat = 2

    var columns: Int = 1 {
        didSet { needsLayout = true }
    }

    /// When set, that tile fills the whole grid and the others are hidden.
    private(set) var soloTile: CameraTileView?

    /// Called when a drag-to-swap completes over another tile (indices into `tiles`).
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?
    /// Called when a tile is double-clicked (enlarge/restore is decided by the owner).
    var onToggleSolo: ((CameraTileView) -> Void)?

    // Drag session state.
    private weak var dragSourceTile: CameraTileView?
    private weak var highlightedTarget: CameraTileView?
    private var ghost: CALayer?
    private(set) var isDragging = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Replace the set of tiles shown (preserving the given order).
    func setTiles(_ newTiles: [CameraTileView]) {
        for tile in tiles where !newTiles.contains(tile) {
            tile.removeFromSuperview()
        }
        for tile in newTiles where tile.superview == nil {
            addSubview(tile)
        }
        for tile in newTiles { tile.interactionDelegate = self }
        tiles = newTiles
        // Drop a stale solo reference if that tile is gone.
        if let s = soloTile, !newTiles.contains(s) { soloTile = nil }
        needsLayout = true
    }

    // MARK: - Solo (enlarge)

    func setSolo(_ tile: CameraTileView?) {
        soloTile = tile
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Solo: one tile fills the grid, the rest are hidden (streams stay live).
        if let solo = soloTile, tiles.contains(solo) {
            for tile in tiles { tile.isHidden = (tile !== solo) }
            solo.frame = bounds
            return
        }
        // Not solo → make sure everything is visible again.
        for tile in tiles where tile.isHidden { tile.isHidden = false }

        let n = tiles.count
        guard n > 0 else { return }

        let cols = max(1, min(columns, n))
        let rows = (n + cols - 1) / cols

        let tileW = (bounds.width - spacing * CGFloat(cols - 1)) / CGFloat(cols)
        let tileH = (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)

        // Center a non-full last row so the orphan tile(s) sit balanced under
        // the rows above (e.g. 3 cameras → 2 on top, 1 centered below) instead
        // of leaving a gap on the right. Tiles keep the same size as the others.
        let lastRowCount = n % cols == 0 ? cols : n % cols
        let lastRowOffsetX = lastRowCount == cols
            ? 0
            : (bounds.width - CGFloat(lastRowCount) * tileW - spacing * CGFloat(lastRowCount - 1)) / 2

        for (i, tile) in tiles.enumerated() {
            let r = i / cols
            let c = i % cols
            let isLastRow = r == rows - 1
            let x = (isLastRow ? lastRowOffsetX : 0) + CGFloat(c) * (tileW + spacing)
            // Flip rows for AppKit's bottom-left origin so tile 0 is top-left.
            let y = bounds.height - CGFloat(r + 1) * tileH - CGFloat(r) * spacing
            tile.frame = NSRect(x: x, y: y, width: tileW, height: tileH)
        }
    }

    // MARK: - CameraTileInteractionDelegate

    func tileRequestedSoloToggle(_ tile: CameraTileView) {
        onToggleSolo?(tile)
    }

    func tileBeganDrag(_ tile: CameraTileView, at pointInWindow: NSPoint) {
        // Nothing to swap with a single tile, and dragging in solo makes no sense.
        guard tiles.count > 1, soloTile == nil else { return }
        isDragging = true
        dragSourceTile = tile
        tile.layer?.opacity = 0.3
        tiles.forEach { $0.hoverSuppressed = true; $0.hideHoverControls() }

        let g = makeGhost(name: tile.cameraName, tileSize: tile.frame.size)
        layer?.addSublayer(g)
        ghost = g
        moveGhost(toWindowPoint: pointInWindow)
    }

    func tileDraggedTo(pointInWindow point: NSPoint) {
        guard isDragging else { return }
        moveGhost(toWindowPoint: point)
        let local = convert(point, from: nil)
        let target = tiles.first { $0 !== dragSourceTile && $0.frame.contains(local) }
        if target !== highlightedTarget {
            highlightedTarget?.setDropHighlight(false)
            highlightedTarget = target
            target?.setDropHighlight(true)
        }
    }

    func tileEndedDrag(at pointInWindow: NSPoint) {
        guard isDragging else { return }
        let local = convert(pointInWindow, from: nil)
        let target = tiles.first { $0 !== dragSourceTile && $0.frame.contains(local) }
        finishDrag(swapWith: target)
    }

    /// Cancel an in-progress drag (e.g. the user pressed Esc). No-op otherwise.
    func cancelActiveDrag() {
        guard isDragging else { return }
        finishDrag(swapWith: nil)
    }

    private func finishDrag(swapWith target: CameraTileView?) {
        let source = dragSourceTile
        highlightedTarget?.setDropHighlight(false)
        highlightedTarget = nil
        ghost?.removeFromSuperlayer()
        ghost = nil
        source?.layer?.opacity = 1.0
        tiles.forEach { $0.hoverSuppressed = false }
        isDragging = false
        dragSourceTile = nil

        if let source, let target,
           let from = tiles.firstIndex(of: source),
           let to = tiles.firstIndex(of: target), from != to {
            onReorder?(from, to)   // owner swaps the model + persists + re-lays out
        }
        // No valid target → no-op; the source tile is already restored above.
    }

    // MARK: - Drag ghost

    /// A synthetic placeholder (name on a dark rounded rect) — NOT a snapshot of
    /// the tile, because AVSampleBufferDisplayLayer snapshots come back blank.
    private func makeGhost(name: String, tileSize: NSSize) -> CALayer {
        let w = max(80, tileSize.width * 0.6)
        let h = max(48, tileSize.height * 0.6)
        let scale = window?.backingScaleFactor ?? 2

        let g = CALayer()
        g.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        g.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        g.borderColor = NSColor.controlAccentColor.cgColor
        g.borderWidth = 2
        g.cornerRadius = 6
        g.opacity = 0.9
        g.shadowColor = NSColor.black.cgColor
        g.shadowOpacity = 0.5
        g.shadowRadius = 8
        g.shadowOffset = .zero

        let text = CATextLayer()
        text.string = name
        text.fontSize = 13
        text.foregroundColor = NSColor.white.cgColor
        text.alignmentMode = .center
        text.truncationMode = .end
        text.contentsScale = scale
        text.frame = CGRect(x: 6, y: (h - 18) / 2, width: w - 12, height: 18)
        g.addSublayer(text)
        return g
    }

    private func moveGhost(toWindowPoint p: NSPoint) {
        guard let ghost else { return }
        let local = convert(p, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // follow the cursor with no lag
        ghost.position = local                   // anchorPoint (0.5,0.5) → centered on cursor
        CATransaction.commit()
    }
}
