import CoreGraphics

/// Size of the large preview in the collection's Single View.
///
/// Long content: a capture whose whole-image fit would be much narrower than its fit-to-width size
/// (a full-page capture) is shown at its fit-to-width size instead and scrolls vertically. A wide,
/// short capture (a full header) fits to width. Never upscaled, like the grid.
extension GridLayout {
    /// Below this fraction of its fit-to-width scale, a capture scrolls at fit-to-width instead.
    public static let scrollThreshold: CGFloat = 0.5

    public struct Preview: Equatable, Sendable {
        /// Displayed image size; taller than the area when `scrolls`.
        public var imageSize: CGSize
        public var scrolls: Bool
    }

    /// - Parameters:
    ///   - natural: the capture's natural size, in points.
    ///   - area: the space for the image (any padding already subtracted).
    public static func preview(_ natural: CGSize, in area: CGSize) -> Preview {
        let width = max(1, area.width), height = max(1, area.height)
        let n = CGSize(width: max(1, natural.width), height: max(1, natural.height))
        let fitWidth = min(1, width / n.width)
        let fitAll = min(fitWidth, height / n.height)
        let scale = fitAll < fitWidth * scrollThreshold ? fitWidth : fitAll
        let image = CGSize(width: max(1, (n.width * scale).rounded()), height: max(1, (n.height * scale).rounded()))
        return Preview(imageSize: image, scrolls: image.height > height)
    }
}
