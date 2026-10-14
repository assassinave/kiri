import AppKit
import SwiftUI
import Combine
import KiriCore

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Cards may sit partly off-screen (vertical mode); don't let AppKit pull the panel back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the floating panel. The panel is sized to just the cards so empty screen stays clickable.
@MainActor
final class ShelfController {
    private let model: AppModel
    private let state = ShelfState()
    private let panel: ShelfPanel
    private var bag = Set<AnyCancellable>()
    /// Screen the shelf lives on; follows the most recent capture.
    var targetScreen: NSScreen?
    /// Called by the shelf's "show all" pill.
    var onShowAll: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = ShelfRootView(state: state, onClose: { [weak model] id in
                                     model?.remove(id)
                                     Sounds.playDelete()
                                 },
                                 onShowAll: { [weak self] in self?.onShowAll?() })
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        Publishers.CombineLatest3(model.$shots, model.$style, model.$isEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shots, style, enabled in self?.refresh(shots: shots, style: style, enabled: enabled) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refresh(shots: self.model.shots, style: self.model.style, enabled: self.model.isEnabled)
            }
            .store(in: &bag)
    }

    private func refresh(shots: [Shot], style: ShelfStyle, enabled: Bool) {
        let screen = targetScreen.flatMap { s in NSScreen.screens.first { $0 == s } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard enabled, !shots.isEmpty, let screen,
              let geo = ShelfLayout.geometry(
                count: shots.count, style: style, screenSize: screen.frame.size,
                topInset: screen.frame.maxY - screen.visibleFrame.maxY,
                bottomInset: screen.visibleFrame.minY - screen.frame.minY)
        else {
            panel.orderOut(nil)
            state.shots = shots
            state.style = style
            state.geometry = nil
            return
        }
        let r = geo.panelRect
        let frame = NSRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY,
                           width: r.width, height: r.height)
        panel.setFrame(frame, display: false)
        state.shots = shots
        state.style = style
        state.geometry = geo
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
