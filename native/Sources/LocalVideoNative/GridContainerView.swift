import AppKit

/// Arranges camera tiles in a grid with a configurable number of columns.
/// Tiles can be swapped at runtime via `setTiles` (when cameras are added or
/// removed); changing `columns` only re-lays them out. Neither disturbs the
/// video pipeline — layout just moves frames.
final class GridContainerView: NSView {

    private(set) var tiles: [CameraTileView] = []
    private let spacing: CGFloat = 2

    var columns: Int = 1 {
        didSet { needsLayout = true }
    }

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
        tiles = newTiles
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = tiles.count
        guard n > 0, bounds.width > 0, bounds.height > 0 else { return }

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
}
