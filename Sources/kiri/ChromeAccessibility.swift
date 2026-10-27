import AppKit
import ApplicationServices

/// Whether Google Chrome exposes web page elements to Accessibility, which element picking needs.
///
/// Chrome 155 builds a page's element tree only while its own accessibility mode is on. It ignores the
/// attributes other apps set to turn that on (`AXManualAccessibility`, `AXEnhancedUserInterface`; tested
/// Oct 2026), so the user turns it on at chrome://accessibility. It only lasts while that tab is open
/// (closing it turns the mode off within 0.5s; Chrome 155, Oct 2026) and isn't saved across restarts.
/// Without it a page hit-tests as one bare `AXScrollArea`.
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

    /// Quits Chrome (after asking) and reopens it with `--force-renderer-accessibility`, which keeps the
    /// mode on with no tab open and survives Chrome relaunching itself (chrome://restart; tested Oct 2026),
    /// but not the user quitting and reopening Chrome.
    @MainActor static func relaunchWithAccessibility() {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if !running.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Relaunch Chrome?"
            alert.informativeText = "Chrome will quit and reopen with element picking on. Your tabs come back only if Chrome is set to \u{201C}Continue where you left off\u{201D}. It stays on until you quit Chrome yourself."
            alert.addButton(withTitle: "Relaunch Chrome")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            running.forEach { $0.terminate() }
        }
        // A running Chrome ignores launch arguments, so wait for it to quit first.
        waitForQuit(running, until: Date().addingTimeInterval(10)) {
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--force-renderer-accessibility"]
            NSWorkspace.shared.openApplication(at: chromeURL, configuration: config)
        }
    }

    /// Gives up silently at the deadline, e.g. when Chrome asks to confirm leaving a page and the user stays.
    @MainActor private static func waitForQuit(_ apps: [NSRunningApplication], until deadline: Date,
                                               then launch: @escaping @MainActor () -> Void) {
        if apps.allSatisfy(\.isTerminated) { return launch() }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { waitForQuit(apps, until: deadline, then: launch) }
        }
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }
}
