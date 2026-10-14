import CoreGraphics

/// Layout for the grid with one capture enlarged: the enlarged capture on the left, the others in a
/// left-aligned vertical stack to its right. The pair is centered in the area.
///
/// Long content: a capture whose whole-image fit would be much narrower than its fit-to-width size
/// (a full-page capture) is shown at its fit-to-width size instead and scrolls vertically. A wide,
/// short capture (a full header) fits to width. Never upscaled, like the grid.
extension GridLayout {
    /// Width of the stack column, as a share of the area, clamped to `stackWidthRange`.
    public static let stackWidthShare: CGFloat = 0.2
    public static let stackWidthRange: ClosedRange<CGFloat> = 140...200
    /// Tallest a thumbnail in the stack may be.
    public static let stackThumbMaxHeight: CGFloat = 140
    public static let stackSpacing: CGFloat = 16
    /// Below this fraction of its fit-to-width scale, a capture scrolls at fit-to-width instead.
    public static let scrollThreshold: CGFloat = 0.5

    public struct ZoomArrangement: Equatable, Sendable {
        /// The enlarged capture. Its `frame` is in `mainViewport` coordinates (origin zero); taller
        /// than the viewport when `mainScrolls`.
        public var main: Tile
        /// Visible rect of the enlarged capture, in the coordinates of the full area given to `zoomed`.
        public var mainViewport: CGRect
        public var mainScrolls: Bool
        /// Indices into the input of the stacked captures, in order (the focus is left out).
        public var stackIndices: [Int]
        /// Stacked tiles, in column coordinates: left-aligned at x 0, from y 0 down.
        public var stack: [Tile]
        /// Visible rect of the stack column, in area coordinates; empty when nothing is stacked.
        public var stackFrame: CGRect
        /// Full height of the stack; it scrolls when this is taller than `stackFrame`.
        public var stackContentHeight: CGFloat
    }

    /// - Parameters:
    ///   - sizes: natural sizes of the captures, in points, in display order.
    ///   - focus: index of the enlarged capture.
    ///   - size: the full area the grid is shown in (padding is subtracted here).
    public static func zoomed(_ sizes: [CGSize], focus: Int, in size: CGSize) -> ZoomArrangement {
        let width = max(1, size.width - 2 * padding)
        let height = max(1, size.height - 2 * padding)
        let stackIndices = sizes.indices.filter { $0 != focus }

        // Stack: thumbnails scaled to the column, left-aligned.
        let stackWidth = stackIndices.isEmpty ? 0
            : min(max(width * stackWidthShare, stackWidthRange.lowerBound), stackWidthRange.upperBound)
        var stack: [Tile] = []
        var y: CGFloat = 0
        for i in stackIndices {
            let image = scaled(sizes[i], by: { min(1, stackWidth / $0.width, stackThumbMaxHeight / $0.height) })
            let (slot, compact) = slot(for: image)
            stack.append(Tile(frame: CGRect(x: 0, y: y, width: slot.width, height: slot.height),
                              imageSize: image, compact: compact))
            y += slot.height + stackSpacing
        }
        let stackContentHeight = stack.isEmpty ? 0 : y - stackSpacing

        // Enlarged capture: fit the area beside the stack, unless that makes long content too small.
        let mainWidth = max(1, width - (stack.isEmpty ? 0 : stackWidth + spacing))
        let natural = CGSize(width: max(1, sizes[focus].width), height: max(1, sizes[focus].height))
        let fitWidth = min(1, mainWidth / natural.width)
        let fitAll = min(fitWidth, height / natural.height)
        let long = fitAll < fitWidth * scrollThreshold
        let image = scaled(natural, by: { _ in long ? fitWidth : fitAll })
        let (fullSlot, mainCompact) = slot(for: image)
        let mainSlot = CGSize(width: min(fullSlot.width, mainWidth), height: fullSlot.height)
        // Long content scrolls; so does a narrow capture whose control bar doesn't fit under it.
        let mainScrolls = mainSlot.height > height
        let main = Tile(frame: CGRect(origin: .zero, size: mainSlot), imageSize: image, compact: mainCompact)

        // Center the pair; both columns hang from the same top edge.
        let mainVisible = CGSize(width: mainSlot.width, height: min(mainSlot.height, height))
        let stackVisible = min(stackContentHeight, height)
        let pairWidth = mainVisible.width + (stack.isEmpty ? 0 : spacing + stackWidth)
        let pairHeight = max(mainVisible.height, stackVisible)
        let x0 = padding + ((width - pairWidth) / 2).rounded()
        let y0 = padding + ((height - pairHeight) / 2).rounded()
        return ZoomArrangement(
            main: main,
            mainViewport: CGRect(origin: CGPoint(x: x0, y: y0), size: mainVisible),
            mainScrolls: mainScrolls,
            stackIndices: stackIndices,
            stack: stack,
            stackFrame: stack.isEmpty ? .zero
                : CGRect(x: x0 + mainVisible.width + spacing, y: y0, width: stackWidth, height: stackVisible),
            stackContentHeight: stackContentHeight)
    }

    private static func scaled(_ natural: CGSize, by scale: (CGSize) -> CGFloat) -> CGSize {
        let n = CGSize(width: max(1, natural.width), height: max(1, natural.height))
        let s = scale(n)
        return CGSize(width: max(1, (n.width * s).rounded()), height: max(1, (n.height * s).rounded()))
    }

    /// A tile's slot: the image, plus the control bar below it when the image is too small to hold them.
    static func slot(for image: CGSize) -> (slot: CGSize, compact: Bool) {
        let compact = image.width < minInlineSize.width || image.height < minInlineSize.height
        return compact
            ? (CGSize(width: max(image.width, barMinWidth), height: image.height + barGap + barHeight), true)
            : (image, false)
    }
}
