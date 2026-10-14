import AppKit
import ApplicationServices

/// Finds the on-screen bounds of the UI element under a point in another app via the Accessibility API.
/// All coordinates are global, top-left origin (primary display), in points — the space AX and CGWindowList use.
enum ElementHitTester {
    struct Hit {
        let rect: CGRect
        let role: String
    }

    /// Elements thinner than this (e.g. empty text runs) are skipped in favor of their parent.
    private static let minSide: CGFloat = 4

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow Accessibility" prompt if kiri isn't trusted yet.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Apps already asked to expose their full accessibility tree (see `hit`). A relaunched app has a new pid.
    @MainActor private static var manualAccessibilityRequested = Set<pid_t>()

    @MainActor
    static func hit(at point: CGPoint) -> Hit? {
        guard let (pid, windowBounds) = topWindow(at: point) else { return nil }
        // Ask the owning app directly; a system-wide hit-test would land on our own overlay.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Chromium (Chrome, Edge, Arc…) and Electron only build the accessibility tree for web content
        // once an assistive app asks; until then a page hit-tests as a bare AXScrollArea. Apps that don't
        // support the attribute return an error, which is ignored. The tree is built asynchronously, so
        // the first hover after this may still see the scroll area.
        if manualAccessibilityRequested.insert(pid).inserted {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &element) == .success
        else { return nil }
        while let e = element {
            if let f = frame(of: e)?.intersection(windowBounds), f.width >= minSide, f.height >= minSide {
                return Hit(rect: f, role: attribute(e, kAXRoleAttribute) as? String ?? "?")
            }
            element = attribute(e, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    /// Frontmost normal-level window under `point` that isn't ours.
    private static func topWindow(at point: CGPoint) -> (pid_t, CGRect)? {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {  // front to back
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let dict = info[kCGWindowBounds as String] as CFTypeRef?,
                  let bounds = CGRect(dictionaryRepresentation: dict as! CFDictionary),
                  bounds.contains(point)
            else { continue }
            return (pid, bounds)
        }
        return nil
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
