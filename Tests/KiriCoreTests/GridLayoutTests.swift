import Testing
import CoreGraphics
@testable import KiriCore

@Suite struct GridLayoutTests {
    let screen = CGSize(width: 1440, height: 900)
    var available: CGSize { CGSize(width: screen.width - 2 * GridLayout.padding,
                                   height: screen.height - 2 * GridLayout.padding) }
    let retinaShot = CGSize(width: 1440, height: 900)

    func shots(_ n: Int, _ size: CGSize) -> [CGSize] { Array(repeating: size, count: n) }

    @Test func testAllShotsFitWithoutScrolling() {
        let mixes: [[CGSize]] = (1...20).map { shots($0, retinaShot) } + [
            [CGSize(width: 616, height: 346), CGSize(width: 1300, height: 40), CGSize(width: 1300, height: 40)],
            shots(20, CGSize(width: 1300, height: 30)),
            shots(20, CGSize(width: 20, height: 800)),
        ]
        for sizes in mixes {
            let a = GridLayout.arrange(sizes, in: screen)
            #expect(a.tiles.count == sizes.count)
            #expect(a.contentSize.width <= available.width)
            #expect(a.contentSize.height <= available.height)
            for t in a.tiles {
                #expect(t.frame.minX >= 0 && t.frame.maxX <= a.contentSize.width)
                #expect(t.frame.minY >= 0 && t.frame.maxY <= a.contentSize.height)
            }
        }
    }

    @Test func testTilesDontOverlap() {
        let sizes = [CGSize(width: 616, height: 346), CGSize(width: 1300, height: 40),
                     CGSize(width: 300, height: 900), CGSize(width: 1300, height: 40)] + shots(6, retinaShot)
        let tiles = GridLayout.arrange(sizes, in: screen).tiles
        for i in tiles.indices {
            for j in tiles.indices where j > i {
                #expect(!tiles[i].frame.intersects(tiles[j].frame))
            }
        }
    }

    @Test func testKeepsAspectAndNeverUpscales() {
        let sizes = [CGSize(width: 200, height: 100), retinaShot, CGSize(width: 1300, height: 40)]
        let tiles = GridLayout.arrange(sizes, in: screen).tiles
        for (natural, t) in zip(sizes, tiles) {
            #expect(t.imageSize.width <= natural.width && t.imageSize.height <= natural.height)
            #expect(abs(t.imageSize.width / t.imageSize.height - natural.width / natural.height)
                    < natural.width / natural.height * 0.05)
        }
        #expect(tiles[0].imageSize == CGSize(width: 200, height: 100))
    }

    @Test func testShrinksAsCountGrows() {
        var previous = CGFloat.infinity
        for n in 1...20 {
            let h = GridLayout.arrange(shots(n, retinaShot), in: screen).tiles[0].imageSize.height
            #expect(h <= previous)
            previous = h
        }
    }

    @Test func testFewShotsAreLargerThanOldFixedCell() {
        #expect(GridLayout.arrange(shots(4, retinaShot), in: screen).tiles[0].imageSize.width > 260)
    }

    @Test func testHeightCappedAtMax() {
        let t = GridLayout.arrange([CGSize(width: 3000, height: 3000)], in: CGSize(width: 5000, height: 3000)).tiles[0]
        #expect(t.imageSize.height == GridLayout.maxHeight)
    }

    @Test func testGrowsWithScreen() {
        let small = GridLayout.arrange(shots(6, retinaShot), in: screen).tiles[0].imageSize.height
        let large = GridLayout.arrange(shots(6, retinaShot), in: CGSize(width: 2560, height: 1440)).tiles[0].imageSize.height
        #expect(large > small)
    }

    /// The case from the bug report: a regular capture and two long, short ones.
    /// The long ones get their own rows (stacked), and since they're too short for inline controls
    /// they're compact, with room reserved for the bar below.
    @Test func testLongShortCapturesStackAndGetABar() {
        let sizes = [CGSize(width: 616, height: 346), CGSize(width: 1300, height: 40), CGSize(width: 1300, height: 40)]
        let tiles = GridLayout.arrange(sizes, in: screen).tiles
        #expect(tiles[1].frame.minY >= tiles[0].frame.maxY)
        #expect(tiles[2].frame.minY >= tiles[1].frame.maxY)
        #expect(!tiles[0].compact)
        for t in tiles[1...] {
            #expect(t.compact)
            #expect(t.frame.height >= t.imageSize.height + GridLayout.barGap + GridLayout.barHeight)
        }
    }

    @Test func testNarrowCaptureBarIsWiderThanImage() {
        let t = GridLayout.arrange([CGSize(width: 20, height: 800)], in: screen).tiles[0]
        #expect(t.compact)
        #expect(t.frame.width >= GridLayout.barMinWidth)
    }

    @Test func testLargeCapturesAreNotCompact() {
        for t in GridLayout.arrange(shots(20, retinaShot), in: screen).tiles {
            #expect(!t.compact)
        }
    }
}
