import CoreGraphics

/// Layout for the "show all" grid: captures keep their aspect ratio and are packed into rows, in
/// order, with the largest row height at which every shot fits the available area without scrolling
/// (capped at `maxHeight`, never upscaled). A capture too wide to share a row gets one of its own, so
/// long, short captures stack vertically.
///
/// A tile too small to hold its controls (×, pixel badge, note button) inside the image is `compact`:
/// the controls go in a bar below it, and its slot reserves room for that bar.
public enum GridLayout {
    public static let maxHeight: CGFloat = 520
    public static let spacing: CGFloat = 28
    public static let padding: CGFloat = 60

    /// Smallest image that holds the controls inside it: × at the top, badge and note button at the
    /// bottom, with 6pt padding. The width allows for a long pixel badge ("2560×1440") beside the note button.
    public static let minInlineSize = CGSize(width: 110, height: 56)
    /// Bar under a compact tile: gap above it, its height, and its minimum width (badge, note, ×).
    public static let barGap: CGFloat = 4
    public static let barHeight: CGFloat = 24
    public static let barMinWidth: CGFloat = 130

    public struct Tile: Equatable, Sendable {
        /// Slot for the tile (image, plus the bar below it when compact), in content coordinates.
        public var frame: CGRect
        /// Displayed image size; the image is centered horizontally at the top of `frame`.
        public var imageSize: CGSize
        public var compact: Bool
    }

    public struct Arrangement: Equatable, Sendable {
        public var tiles: [Tile]
        /// Size of the block of rows (padding excluded).
        public var contentSize: CGSize
    }

    /// - Parameters:
    ///   - sizes: natural sizes of the captures, in points, in display order.
    ///   - size: the full area the grid is shown in (padding is subtracted here).
    public static func arrange(_ sizes: [CGSize], in size: CGSize) -> Arrangement {
        let width = max(1, size.width - 2 * padding)
        let height = max(1, size.height - 2 * padding)
        var last = Arrangement(tiles: [], contentSize: .zero)
        var row = maxHeight
        while row >= 1 {
            last = arrange(sizes, rowHeight: row, width: width)
            if last.contentSize.height <= height { return last }
            row -= 1
        }
        return last
    }

    /// Packs the captures, scaled to at most `rowHeight` tall, greedily into rows no wider than `width`.
    static func arrange(_ sizes: [CGSize], rowHeight: CGFloat, width: CGFloat) -> Arrangement {
        struct Item { var image: CGSize; var slot: CGSize; var compact: Bool }
        let items = sizes.map { natural -> Item in
            let w = max(1, natural.width), h = max(1, natural.height)
            let scale = min(1, rowHeight / h, width / w)
            let image = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
            let (slot, compact) = slot(for: image)
            return Item(image: image, slot: slot, compact: compact)
        }

        // Greedy rows, in order.
        var rows: [[Int]] = []
        var rowWidth: CGFloat = 0
        for (i, item) in items.enumerated() {
            if let current = rows.last, !current.isEmpty, rowWidth + spacing + item.slot.width <= width {
                rows[rows.count - 1].append(i)
                rowWidth += spacing + item.slot.width
            } else {
                rows.append([i])
                rowWidth = item.slot.width
            }
        }

        // Rows are centered horizontally; tiles are centered vertically within their row.
        let rowWidths = rows.map { r in r.reduce(0) { $0 + items[$1].slot.width } + CGFloat(r.count - 1) * spacing }
        let contentWidth = rowWidths.max() ?? 0
        var tiles = [Tile?](repeating: nil, count: items.count)
        var y: CGFloat = 0
        for (r, indices) in rows.enumerated() {
            let rowH = indices.map { items[$0].slot.height }.max() ?? 0
            var x = ((contentWidth - rowWidths[r]) / 2).rounded()
            for i in indices {
                let item = items[i]
                let origin = CGPoint(x: x, y: y + ((rowH - item.slot.height) / 2).rounded())
                tiles[i] = Tile(frame: CGRect(origin: origin, size: item.slot), imageSize: item.image, compact: item.compact)
                x += item.slot.width + spacing
            }
            y += rowH + spacing
        }
        let contentHeight = rows.isEmpty ? 0 : y - spacing
        return Arrangement(tiles: tiles.compactMap { $0 }, contentSize: CGSize(width: contentWidth, height: contentHeight))
    }
}
