import Testing
import CoreGraphics
@testable import KiriCore

@Suite struct ShelfLayoutTests {
    let screen = CGSize(width: 1440, height: 900)

    func geo(_ n: Int, _ style: ShelfStyle) -> ShelfGeometry? {
        ShelfLayout.geometry(count: n, style: style, screenSize: screen, topInset: 38, bottomInset: 70)
    }

    @Test func testEmptyHasNoGeometry() {
        #expect(geo(0, .default) == nil)
    }

    @Test func testCardAspect() {
        let s = ShelfLayout.cardSize(width: 160)
        #expect(s.height == 100)
    }

    @Test func testRotationAlternates() {
        let g = geo(4, .default)!
        #expect(g.placements.map(\.rotation) == [3.1, -3.1, 3.1, -3.1])
    }

    @Test func testHorizontalIsCenteredOnScreen() {
        let g = geo(5, .default)!
        // Union of unrotated cards, converted to screen coords, is centered.
        let size = ShelfLayout.cardSize(width: 122)
        let first = g.placements.first!.origin.x + g.panelRect.minX
        let last = g.placements.last!.origin.x + g.panelRect.minX + size.width
        #expect(abs(((first + last) / 2) - (screen.width / 2)) <= 0.5)
    }

    @Test func testHorizontalOverlapStep() {
        let g = geo(3, .default)!
        let dx = g.placements[1].origin.x - g.placements[0].origin.x
        #expect(abs((dx) - (122 * 0.3)) <= 0.01)
    }

    @Test func testOverlapTightensWhenTooMany() {
        var style = ShelfStyle.default
        style.overlap = 0
        let g = geo(40, style)!
        let size = ShelfLayout.cardSize(width: 122)
        let first = g.placements.first!.origin.x
        let last = g.placements.last!.origin.x + size.width
        #expect(last - first <= screen.width - 2 * ShelfLayout.screenMargin + 0.5)
    }

    @Test func testVerticalRightHides40Percent() {
        var style = ShelfStyle.default
        style.orientation = .vertical
        style.edge = .right
        let g = geo(3, style)!
        let size = ShelfLayout.cardSize(width: 122)
        let x = g.placements[0].origin.x + g.panelRect.minX
        #expect(abs((x + size.width - screen.width) - (size.width * 0.4)) <= 0.01)
    }

    @Test func testVerticalLeftHides40Percent() {
        var style = ShelfStyle.default
        style.orientation = .vertical
        style.edge = .left
        let g = geo(3, style)!
        let size = ShelfLayout.cardSize(width: 122)
        let x = g.placements[0].origin.x + g.panelRect.minX
        #expect(abs((x) - (-size.width * 0.4)) <= 0.01)
    }

    @Test func testVerticalStaysBelowMenuBar() {
        var style = ShelfStyle.default
        style.orientation = .vertical
        let g = geo(3, style)!
        let y = g.placements[0].origin.y + g.panelRect.minY
        #expect(y >= 38 + ShelfLayout.screenMargin - 0.01)
    }

    @Test func testHorizontalAlwaysTopEdge() {
        var style = ShelfStyle.default
        style.edge = .left
        #expect(style.effectiveEdge == .top)
    }

    @Test func testPanelContainsRotatedCards() {
        let g = geo(2, .default)!
        let size = ShelfLayout.cardSize(width: 122)
        for p in g.placements {
            #expect(p.origin.x >= 0)
            #expect(p.origin.y >= 0)
            #expect(p.origin.x + size.width <= g.panelRect.width)
            #expect(p.origin.y + size.height <= g.panelRect.height)
        }
    }

    @Test func testHorizontalPillRightOfLastCardOnScreen() {
        for n in [1, 5, 40] {
            let g = geo(n, .default)!
            let size = ShelfLayout.cardSize(width: 122)
            let lastRight = g.placements.last!.origin.x + size.width
            let pillLeft = g.pillCenter.x - ShelfLayout.pillSize.width / 2
            #expect(pillLeft > lastRight)
            #expect(g.pillCenter.x + g.panelRect.minX + ShelfLayout.pillSize.width / 2 <= screen.width)
        }
    }

    @Test func testVerticalPillBelowLastCardOnScreen() {
        var style = ShelfStyle.default
        style.orientation = .vertical
        for edge in [ShelfEdge.left, .right] {
            style.edge = edge
            for n in [1, 40] {
                let g = geo(n, style)!
                let size = ShelfLayout.cardSize(width: 122)
                let lastBottom = g.placements.last!.origin.y + size.height
                let pillTop = g.pillCenter.y - ShelfLayout.pillSize.height / 2
                let pillScreen = CGPoint(x: g.pillCenter.x + g.panelRect.minX, y: g.pillCenter.y + g.panelRect.minY)
                #expect(pillTop > lastBottom)
                #expect(pillScreen.y + ShelfLayout.pillSize.height / 2 <= screen.height - 70)
                #expect(pillScreen.x - ShelfLayout.pillSize.width / 2 >= 0)
                #expect(pillScreen.x + ShelfLayout.pillSize.width / 2 <= screen.width)
            }
        }
    }
}
