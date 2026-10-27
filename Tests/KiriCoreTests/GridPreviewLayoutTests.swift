import Testing
import CoreGraphics
@testable import KiriCore

@Suite struct GridPreviewLayoutTests {
    let area = CGSize(width: 900, height: 500)
    let retinaShot = CGSize(width: 1440, height: 900)
    let header = CGSize(width: 1440, height: 64)
    let fullPage = CGSize(width: 1280, height: 6000)

    @Test func testScreenshotFitsWithoutScrollingAndIsntUpscaled() {
        let p = GridLayout.preview(retinaShot, in: area)
        #expect(!p.scrolls)
        #expect(p.imageSize.width <= area.width && p.imageSize.height <= area.height)
        #expect(p.imageSize.height == area.height)  // height-bound at this aspect
        let ratio = p.imageSize.width / p.imageSize.height
        #expect(abs(ratio - retinaShot.width / retinaShot.height) < 0.02)

        let small = CGSize(width: 300, height: 200)
        #expect(GridLayout.preview(small, in: area).imageSize == small)
    }

    @Test func testFullPageCaptureScrollsAtFitToWidth() {
        let p = GridLayout.preview(fullPage, in: area)
        #expect(p.scrolls)
        #expect(p.imageSize.width == area.width)
        #expect(p.imageSize.height > area.height)
    }

    @Test func testModeratelyTallCaptureFitsInsteadOfScrolling() {
        // Fit-all keeps more than half the fit-to-width scale, so it isn't treated as long content.
        let p = GridLayout.preview(CGSize(width: 800, height: 700), in: area)
        #expect(!p.scrolls)
        #expect(p.imageSize.height <= area.height)
    }

    @Test func testHeaderFitsToWidth() {
        let p = GridLayout.preview(header, in: area)
        #expect(!p.scrolls)
        #expect(p.imageSize.width == area.width)
        #expect(p.imageSize.height < 64)
    }

    @Test func testNarrowTallCaptureScrolls() {
        let p = GridLayout.preview(CGSize(width: 40, height: 3000), in: area)
        #expect(p.imageSize.width == 40)  // not upscaled to the width
        #expect(p.scrolls)
    }
}
