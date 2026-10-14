import AppKit
import ApplicationServices

/// Whether Google Chrome exposes web page elements to Accessibility, which element picking needs.
///
/// Chrome 155 builds a page's element tree only while its own accessibility mode is on. It ignores the
/// attributes other apps set to turn that on (`AXManualAccessibility`, `AXEnhancedUserInterface`; tested
/// Oct 2026), so the user turns it on at chrome://accessibility. Chrome doesn't save that, so it's off
/// again after every Chrome restart. Without it a page hit-tests as one bare `AXScrollArea`.
enum ChromeAccessibility {
    enum State: Equatable {
        case notRunning
        case noWindows
        /// kiri itself isn't trusted for Accessibility, so Chrome can't be inspected.
        case unknown
        case on
        case off
    }

    static let bundleIdentifier = "com.google.Chrome"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    /// Looks for a web page (`AXWebArea`) in Chrome's windows; it only exists while the mode is on.
    /// Safe to call off the main thread. Takes ~40ms with a couple of windows open.
    static func state() -> State {
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return .notRunning }
        guard ElementHitTester.isTrusted else { return .unknown }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        guard !windows.isEmpty else { return .noWindows }
        // Breadth-first; the web area sits about 10 levels below its window.
        var queue = windows.map { ($0, 0) }
        var visited = 0
        while !queue.isEmpty, visited < 2000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if attribute(element, kAXRoleAttribute) as? String == "AXWebArea" { return .on }
            if depth < 15, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue += children.map { ($0, depth + 1) }
            }
        }
        return .off
    }

    /// Opens chrome://accessibility in Chrome, where the user turns on "Native accessibility API support"
    /// and "Web accessibility".
    static func openSettingsPage() {
        guard let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let url = URL(string: "chrome://accessibility") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
