import Testing
import CoreGraphics
@testable import KiriCore

@Suite struct GridZoomLayoutTests {
    let screen = CGSize(width: 1440, height: 900)
    var area: CGRect { CGRect(origin: .zero, size: screen).insetBy(dx: GridLayout.padding, dy: GridLayout.padding) }
    let retinaShot = CGSize(width: 1440, height: 900)
    let header = CGSize(width: 1440, height: 64)
    let fullPage = CGSize(width: 1280, height: 6000)

    @Test func testStackHoldsEveryOtherShotInOrder() {
        let sizes = [retinaShot, header, fullPage, CGSize(width: 300, height: 400)]
        let z = GridLayout.zoomed(sizes, focus: 1, in: screen)
        #expect(z.stackIndices == [0, 2, 3])
        #expect(z.stack.count == 3)
    }

    @Test func testStackIsLeftAlignedAndInsideItsColumn() {
        let sizes = [retinaShot, header, fullPage, CGSize(width: 300, height: 400), CGSize(width: 20, height: 800)]
        let z = GridLayout.zoomed(sizes, focus: 0, in: screen)
        for t in z.stack {
            #expect(t.frame.minX == 0)
            #expect(t.frame.width <= z.stackFrame.width)
            #expect(t.frame.height <= GridLayout.stackThumbMaxHeight + GridLayout.barGap + GridLayout.barHeight)
        }
        for (a, b) in zip(z.stack, z.stack.dropFirst()) {
            #expect(b.frame.minY == a.frame.maxY + GridLayout.stackSpacing)
        }
        #expect(z.stackContentHeight == z.stack.last!.frame.maxY)
    }

    @Test func testMainAndStackStayInsideTheAreaWithoutOverlapping() {
        for focus in 0..<3 {
            let z = GridLayout.zoomed([retinaShot, header, fullPage], focus: focus, in: screen)
            #expect(area.contains(z.mainViewport))
            #expect(area.contains(z.stackFrame))
            #expect(z.stackFrame.minX >= z.mainViewport.maxX + GridLayout.spacing)
            #expect(z.mainViewport.minY == z.stackFrame.minY)
        }
    }

    @Test func testScreenshotFitsWithoutScrollingAndIsntUpscaled() {
        let z = GridLayout.zoomed([retinaShot, header], focus: 0, in: screen)
        #expect(!z.mainScrolls)
        #expect(z.main.frame.size == z.mainViewport.size)
        #expect(z.main.imageSize.width <= retinaShot.width && z.main.imageSize.height <= area.height)
        let ratio = z.main.imageSize.width / z.main.imageSize.height
        #expect(abs(ratio - retinaShot.width / retinaShot.height) < 0.02)

        let small = CGSize(width: 300, height: 200)
        #expect(GridLayout.zoomed([small, header], focus: 0, in: screen).main.imageSize == small)
    }

    @Test func testFullPageCaptureScrollsAtFitToWidth() {
        let z = GridLayout.zoomed([fullPage, retinaShot], focus: 0, in: screen)
        #expect(z.mainScrolls)
        #expect(z.main.imageSize.width == z.mainViewport.width)
        #expect(z.main.imageSize.height > z.mainViewport.height)
        #expect(z.mainViewport.height == area.height)
    }

    @Test func testModeratelyTallCaptureFitsInsteadOfScrolling() {
        // Fit-all keeps more than half the fit-to-width scale, so it isn't treated as long content.
        let z = GridLayout.zoomed([CGSize(width: 800, height: 1400), retinaShot], focus: 0, in: screen)
        #expect(!z.mainScrolls)
        #expect(z.main.imageSize.height <= area.height)
    }

    @Test func testHeaderFitsToWidth() {
        let z = GridLayout.zoomed([header, retinaShot], focus: 0, in: screen)
        #expect(!z.mainScrolls)
        let mainWidth = area.width - z.stackFrame.width - GridLayout.spacing
        #expect(z.main.imageSize.width == mainWidth)
        #expect(z.main.imageSize.height < 64)
    }

    @Test func testNarrowTallCaptureGetsItsBarAndScrollsIfNeeded() {
        let z = GridLayout.zoomed([CGSize(width: 40, height: 3000), retinaShot], focus: 0, in: screen)
        #expect(z.main.compact)
        #expect(z.main.frame.width >= GridLayout.barMinWidth)
        #expect(z.mainScrolls)
    }

    @Test func testLongStackScrolls() {
        let sizes = Array(repeating: retinaShot, count: 20)
        let z = GridLayout.zoomed(sizes, focus: 5, in: screen)
        #expect(z.stack.count == 19)
        #expect(z.stackContentHeight > z.stackFrame.height)
        #expect(z.stackFrame.height == area.height)
    }

    @Test func testSingleShotHasNoStack() {
        let z = GridLayout.zoomed([retinaShot], focus: 0, in: screen)
        #expect(z.stack.isEmpty && z.stackIndices.isEmpty)
        #expect(z.stackFrame == .zero)
        #expect(abs(z.mainViewport.midX - screen.width / 2) <= 1)
    }
}
