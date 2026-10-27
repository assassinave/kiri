import AppKit
import SwiftUI
import Combine
import KiriCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private lazy var shelf = ShelfController(model: model)
    private lazy var grid = GridController(model: model)
    private let hotkeys = HotkeyManager()
    private let selector = RegionSelector()
    private let liveMirror = LiveMirror()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "Capture Region", action: #selector(captureNow), keyEquivalent: "")
    private let showAllItem = NSMenuItem(title: "Show All", action: #selector(showAll), keyEquivalent: "")
    private let clearItem = NSMenuItem(title: "Clear All", action: #selector(clearAll), keyEquivalent: "")
    /// Chrome's accessibility mode (see `ChromeAccessibility`); hidden unless Chrome has a window open.
    private let chromeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        shelf.onShowAll = { [weak self] in self?.grid.show() }
        setUpStatusItem()
        hotkeys.onTrigger = { [weak self] action in
            switch action {
            case .capture: self?.captureNow()
            case .showAll: self?.grid.toggle()
            }
        }

        // Re-register the hotkeys whenever they or the enabled state change; persist all settings.
        Publishers.CombineLatest3(model.$hotkey, model.$showAllHotkey, model.$isEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] capture, showAll, enabled in
                guard let self else { return }
                if enabled {
                    self.model.hotkeyError = self.hotkeys.register(capture, for: .capture)
                    if showAll == capture {
                        self.hotkeys.unregister(.showAll)
                        self.model.showAllHotkeyError = "Same as the capture shortcut."
                    } else {
                        self.model.showAllHotkeyError = self.hotkeys.register(showAll, for: .showAll)
                    }
                } else {
                    self.hotkeys.unregister(.capture)
                    self.hotkeys.unregister(.showAll)
                    self.model.hotkeyError = nil
                    self.model.showAllHotkeyError = nil
                    self.grid.hide()
                }
            }
            .store(in: &bag)
        Publishers.Merge4(model.$style.map { _ in () }, model.$isEnabled.map { _ in () },
                          model.$hotkey.map { _ in () }, model.$showAllHotkey.map { _ in () })
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.model.persist() }
            .store(in: &bag)
        // Mirror the shelf to disk (captures, deletes, note edits) for agents; debounced so typing a note
        // doesn't rewrite the file on every keystroke.
        model.$shots
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.liveMirror.sync($0) }
            .store(in: &bag)

        // One window for every permission, instead of prompts spread across captures and dictation.
        // Denied Microphone / Speech Recognition don't bring it back; those can be told apart from "never asked".
        if Permission.allCases.contains(where: \.wasNeverAsked) { openPermissions() }
    }

    // MARK: Menu

    /// The kiri "K" from `kiri.svg` (24 × 18.18 viewBox), drawn as a template image so the menu bar tints it.
    private static func menuBarIcon() -> NSImage {
        let scale: CGFloat = 14 / 18.1836   // 14pt tall
        let image = NSImage(size: NSSize(width: 24 * scale, height: 14), flipped: true) { _ in
            let path = NSBezierPath()
            // Top half; the bottom half is its mirror about y = 18.1836 / 2.
            for flip in [false, true] {
                func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                    NSPoint(x: x * scale, y: (flip ? 18.1836 - y : y) * scale)
                }
                path.move(to: p(8.07407, 0))
                path.line(to: p(0, 0))
                path.curve(to: p(4.16772, 7.72009), controlPoint1: p(0, 1.91689), controlPoint2: p(1.24857, 7.72009))
                path.line(to: p(14.5117, 7.72009))
                path.curve(to: p(24, 0), controlPoint1: p(18.3268, 7.72009), controlPoint2: p(20.4067, 4.3042))
                path.curve(to: p(14.4621, 0.887294), controlPoint1: p(16.5028, 0.000711442), controlPoint2: p(15.4781, 0.175496))
                path.line(to: p(8.07407, 5.72277))
                path.close()
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "kiri"
        return image
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self
        for item in [enabledItem, captureItem, showAllItem, clearItem] { item.target = self }
        menu.addItem(enabledItem)
        menu.addItem(.separator())
        menu.addItem(captureItem)
        menu.addItem(showAllItem)
        menu.addItem(clearItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let permissions = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)
        chromeItem.target = self
        chromeItem.isHidden = true
        menu.addItem(chromeItem)
        menu.addItem(NSMenuItem(title: "Quit kiri", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        enabledItem.state = model.isEnabled ? .on : .off
        captureItem.title = "Capture Region  (\(model.hotkey.displayString))"
        captureItem.isEnabled = model.isEnabled
        showAllItem.title = "Show All  (\(model.showAllHotkey.displayString))"
        showAllItem.isEnabled = model.isEnabled
        clearItem.isEnabled = !model.shots.isEmpty
        // The check walks Chrome's accessibility tree, so it runs off the main thread and the item
        // updates while the menu is open.
        DispatchQueue.global(qos: .userInitiated).async {
            let state = ChromeAccessibility.state()
            DispatchQueue.main.async { self.updateChromeItem(state) }
        }
    }

    private func updateChromeItem(_ state: ChromeAccessibility.State) {
        switch state {
        case .on:
            chromeItem.title = "Chrome Element Picking: On"
            chromeItem.action = nil
            chromeItem.isHidden = false
        case .off:
            chromeItem.title = "Chrome Element Picking: Off \u{2014} Relaunch Chrome\u{2026}"
            chromeItem.action = #selector(relaunchChrome)
            chromeItem.isHidden = false
        case .notRunning, .noWindows, .unknown:
            chromeItem.isHidden = true
        }
    }

    @objc private func relaunchChrome() { ChromeAccessibility.relaunchWithAccessibility() }

    @objc private func toggleEnabled() { model.isEnabled.toggle() }
    @objc private func showAll() { grid.show() }
    @objc private func clearAll() {
        model.clear()
        Sounds.playDelete()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "kiri Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openPermissions() {
        // Rebuilt when not showing, so it reopens on step 1.
        if permissionsWindow?.isVisible != true {
            let view = OnboardingView { [weak self] in self?.permissionsWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Set Up kiri"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            permissionsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        permissionsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Capture

    @objc private func captureNow() {
        guard model.isEnabled, !selector.isActive else { return }
        // Element picking needs Accessibility; without it the selector still does drag-to-select,
        // so only missing Screen Recording blocks the capture.
        guard Permission.screenRecording.isGranted else { return openPermissions() }
        selector.begin { [weak self] screen, rect in
            guard let self else { return }
            Task { @MainActor in
                do {
                    let image = try await ScreenCapturer.capture(screen: screen, rect: rect)
                    self.shelf.targetScreen = screen
                    self.model.add(Shot(cgImage: image, scale: screen.backingScaleFactor))
                    Sounds.playCapture()
                } catch {
                    self.selector.end()  // the overlay would otherwise cover the alert
                    self.showError("Capture failed", error.localizedDescription)
                }
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
