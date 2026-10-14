import CoreGraphics

public enum ShelfOrientation: String, CaseIterable, Sendable, Codable {
    case horizontal, vertical
}

public enum ShelfEdge: String, CaseIterable, Sendable, Codable {
    case top, left, right
}

public struct ShelfStyle: Equatable, Sendable, Codable {
    public var orientation: ShelfOrientation
    public var edge: ShelfEdge
    public var cardWidth: CGFloat
    /// Fraction of a card's length covered by the next card (0...0.8).
    public var overlap: CGFloat
    /// Degrees; cards alternate +rotation / -rotation.
    public var rotation: CGFloat
    public var cornerRadius: CGFloat

    public init(orientation: ShelfOrientation, edge: ShelfEdge, cardWidth: CGFloat,
                overlap: CGFloat, rotation: CGFloat, cornerRadius: CGFloat) {
        self.orientation = orientation
        self.edge = edge
        self.cardWidth = cardWidth
        self.overlap = overlap
        self.rotation = rotation
        self.cornerRadius = cornerRadius
    }

    public static let `default` = ShelfStyle(
        orientation: .horizontal, edge: .top,
        cardWidth: 122, overlap: 0.7, rotation: 3.1, cornerRadius: 8)

    /// Horizontal shelves always sit on the top edge; vertical shelves on left or right.
    public var effectiveEdge: ShelfEdge {
        switch orientation {
        case .horizontal: return .top
        case .vertical: return edge == .left ? .left : .right
        }
    }
}

public struct CardPlacement: Equatable, Sendable {
    /// Top-left of the (unrotated) card, relative to the panel's top-left.
    public var origin: CGPoint
    /// Degrees.
    public var rotation: CGFloat
}

public struct ShelfGeometry: Equatable, Sendable {
    /// Panel rect in screen-local, top-left-origin coordinates (may extend past the screen edge).
    public var panelRect: CGRect
    public var placements: [CardPlacement]
    /// Center of the "show all" pill, relative to the panel's top-left.
    public var pillCenter: CGPoint
}

public enum ShelfLayout {
    public static let aspectRatio: CGFloat = 0.625
    /// In vertical orientation this fraction of the card width sits beyond the screen edge.
    public static let verticalHiddenFraction: CGFloat = 0.4
    public static let screenMargin: CGFloat = 12
    public static let hoverLift: CGFloat = 10
    public static let shadowPad: CGFloat = 14
    public static let minStep: CGFloat = 4
    public static let pillSize = CGSize(width: 52, height: 24)
    public static let pillGap: CGFloat = 10

    public static func cardSize(width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * aspectRatio).rounded())
    }

    public static func step(count: Int, cardLength: CGFloat, overlap: CGFloat, available: CGFloat) -> CGFloat {
        var step = cardLength * (1 - overlap)
        if count > 1, cardLength + CGFloat(count - 1) * step > available {
            step = max(minStep, (available - cardLength) / CGFloat(count - 1))
        }
        return step
    }

    /// - Parameters:
    ///   - screenSize: full screen size in points.
    ///   - topInset: menu bar height; bottomInset: dock/bottom reserved height.
    public static func geometry(count: Int, style: ShelfStyle, screenSize: CGSize,
                                topInset: CGFloat, bottomInset: CGFloat) -> ShelfGeometry? {
        guard count > 0 else { return nil }
        let size = cardSize(width: style.cardWidth)
        let horizontal = style.orientation == .horizontal
        let length = horizontal ? size.width : size.height
        // The pill sits after the last card; reserve its length on both ends so the cards stay centered.
        let pillOffset = pillGap + rotationExtra(size: size, degrees: style.rotation)
        let pillLength = pillOffset + (horizontal ? pillSize.width : pillSize.height)
        let available = (horizontal
            ? screenSize.width - 2 * screenMargin
            : screenSize.height - topInset - bottomInset - 2 * screenMargin) - 2 * pillLength
        let step = step(count: count, cardLength: length, overlap: style.overlap, available: available)
        let total = length + CGFloat(count - 1) * step

        var origins: [CGPoint] = []
        for i in 0..<count {
            let along = CGFloat(i) * step
            if horizontal {
                origins.append(CGPoint(x: (screenSize.width - total) / 2 + along,
                                       y: topInset + screenMargin))
            } else {
                let startY = topInset + screenMargin + pillLength + (available - total) / 2
                let x = style.effectiveEdge == .right
                    ? screenSize.width - size.width * (1 - verticalHiddenFraction)
                    : -size.width * verticalHiddenFraction
                origins.append(CGPoint(x: x, y: startY + along))
            }
        }

        let last = origins[count - 1]
        let pill: CGPoint
        if horizontal {
            pill = CGPoint(x: last.x + size.width + pillOffset + pillSize.width / 2,
                           y: last.y + size.height / 2)
        } else {
            // Centered on the part of the card that's on screen.
            let visible = size.width * (1 - verticalHiddenFraction)
            pill = CGPoint(x: style.effectiveEdge == .right ? screenSize.width - visible / 2 : visible / 2,
                           y: last.y + size.height + pillOffset + pillSize.height / 2)
        }
        let pillRect = CGRect(x: pill.x - pillSize.width / 2, y: pill.y - pillSize.height / 2,
                              width: pillSize.width, height: pillSize.height)

        let union = origins.reduce(pillRect) {
            $0.union(CGRect(origin: $1, size: size))
        }
        let pad = rotationExtra(size: size, degrees: style.rotation) + hoverLift + shadowPad
        let panelRect = union.insetBy(dx: -pad, dy: -pad)

        let placements = origins.enumerated().map { i, o in
            CardPlacement(origin: CGPoint(x: o.x - panelRect.minX, y: o.y - panelRect.minY),
                          rotation: i % 2 == 0 ? style.rotation : -style.rotation)
        }
        return ShelfGeometry(panelRect: panelRect, placements: placements,
                             pillCenter: CGPoint(x: pill.x - panelRect.minX, y: pill.y - panelRect.minY))
    }

    /// How far a rotated card's bounding box pokes past its unrotated frame.
    static func rotationExtra(size: CGSize, degrees: CGFloat) -> CGFloat {
        let t = abs(degrees) * .pi / 180
        let w = size.width * cos(t) + size.height * sin(t)
        let h = size.width * sin(t) + size.height * cos(t)
        return max((w - size.width) / 2, (h - size.height) / 2)
    }
}
