import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class OverlayView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onExit: (() -> Void)?
    var onHover: (() -> Void)?
    /// Element under the cursor (from Accessibility), in this view's coordinates.
    var highlight: (rect: CGRect, role: String)? { didSet { needsDisplay = true } }
    private var start: CGPoint?
    private var selection: CGRect?
    /// Single-click captures wait out the double-click interval, since a double-click exits instead.
    private var pendingClick: DispatchWorkItem?
    private var exitOnRelease = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil), clickCount: event.clickCount)
    }
    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { release() }
    override func rightMouseDown(with event: NSEvent) { onExit?() }

    // Points are in this view's coordinates. Called from the NSView handlers above, or by
    // RegionSelector's event tap when the overlay lets mouse events through to the apps below.

    func press(at p: CGPoint, clickCount: Int) {
        if clickCount >= 2 {
            // Double-click: drop the first click's pending capture and exit when the button comes up.
            pendingClick?.cancel()
            pendingClick = nil
            exitOnRelease = true
            return
        }
        start = p
        selection = nil
        needsDisplay = true
    }

    func drag(to p: CGPoint) {
        guard let start else { return }
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    func release() {
        if exitOnRelease {
            exitOnRelease = false
            onExit?()
            return
        }
        let sel = selection
        start = nil
        selection = nil
        needsDisplay = true
        if let sel, sel.width >= 4, sel.height >= 4 {
            onSelect?(sel)
        } else if let hl = highlight?.rect.intersection(bounds), !hl.isEmpty {
            // Plain click captures the highlighted element, unless a second click turns it into an exit.
            let work = DispatchWorkItem { [weak self] in self?.onSelect?(hl) }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let hole: CGRect?
        let label: String
        if let sel = selection {
            hole = sel
            label = "\(Int(sel.width)) × \(Int(sel.height))"
        } else if let hl = highlight {
            hole = hl.rect
            label = "\(hl.role)  \(Int(hl.rect.width)) × \(Int(hl.rect.height))"
        } else {
            hole = nil
            label = ""
        }

        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.appendRect(hole); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()
        guard let hole else { return }
        NSColor.black.withAlphaComponent(0.01).setFill()  // keep selection hit-testable
        hole.fill()
        let border = NSBezierPath(rect: hole)
        if selection != nil {
            NSColor.white.setStroke()
            border.lineWidth = 1
        } else {
            NSColor.systemBlue.setStroke()
            border.lineWidth = 2
        }
        border.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: hole.minX, y: max(0, hole.minY - size.height - 8),
                          width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (label as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }
}

/// Event-tap callback (runs on the main run loop). Swallows clicks so they don't reach the page under the
/// overlay; lets mouse-moved and scroll events through so the page stays hoverable and scrollable.
private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    let selector = Unmanaged<RegionSelector>.fromOpaque(refcon!).takeUnretainedValue()
    return MainActor.assumeIsolated { selector.handleTap(type, event) }
}

/// Dims every screen and lets the user drag a rectangle, or (with Accessibility permission) click the
/// highlighted UI element under the cursor. Stays open for repeated captures until Esc, a double-click,
/// a right-click, or another app becoming active (an alert would otherwise sit under the overlay, with
/// Esc going to that app).
/// With Accessibility, the overlay ignores the mouse and an event tap takes the clicks instead, so the
/// window underneath can still be scrolled while selecting.
@MainActor
final class RegionSelector {
    private var windows: [OverlayWindow] = []
    private var onCapture: (NSScreen, CGRect) -> Void = { _, _ in }
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pressedView: OverlayView?
    private var resignObserver: NSObjectProtocol?

    var isActive: Bool { !windows.isEmpty }

    /// `onCapture` is called once per selection, with a rect in the screen's local coordinates,
    /// top-left origin, in points.
    func begin(onCapture: @escaping (NSScreen, CGRect) -> Void) {
        guard windows.isEmpty else { return }
        self.onCapture = onCapture
        let pickElements = ElementHitTester.isTrusted
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onSelect = { [weak self] rect in self?.onCapture(screen, rect) }
            view.onExit = { [weak self] in self?.end() }
            if pickElements {
                view.onHover = { [weak self] in self?.updateHighlight() }
            }
            window.contentView = view
            windows.append(window)
        }
        if pickElements, installTap() {
            windows.forEach { $0.ignoresMouseEvents = true }
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(w.contentView)
        }
        NSCursor.crosshair.push()
        if pickElements { updateHighlight() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .mouseMoved, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        pressedView = nil
    }

    fileprivate func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .mouseMoved:
            updateHighlight()
            return pass
        case .scrollWheel:
            // The page moves under a stationary cursor; re-hit-test once the scroll has been applied.
            DispatchQueue.main.async { [weak self] in self?.updateHighlight() }
            return pass
        case .leftMouseDown:
            guard let (view, p) = view(at: event.location) else { return nil }
            pressedView = view
            view.press(at: p, clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
        case .leftMouseDragged:
            if let view = pressedView { view.drag(to: local(event.location, in: view)) }
        case .leftMouseUp:
            let view = pressedView
            pressedView = nil
            view?.release()
        case .rightMouseDown:
            end()
        default:
            break
        }
        return nil  // swallow clicks
    }

    /// Converts a global top-left point (CGEvent / AX space) into an overlay view's coordinates.
    private func local(_ p: CGPoint, in view: OverlayView) -> CGPoint {
        let f = view.window?.frame ?? .zero
        return CGPoint(x: p.x - f.minX, y: p.y - (primaryHeight - f.maxY))
    }

    private func view(at p: CGPoint) -> (OverlayView, CGPoint)? {
        for window in windows {
            guard let view = window.contentView as? OverlayView else { continue }
            let lp = local(p, in: view)
            if view.bounds.contains(lp) { return (view, lp) }
        }
        return nil
    }

    private var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    // MARK: Highlight

    /// Re-hit-test scheduled after a coarse result (see `updateHighlight`).
    private var refineHit: DispatchWorkItem?

    private func updateHighlight() {
        refineHit?.cancel()
        refineHit = nil
        guard isActive else { return }
        // AX / CGWindowList space: global, top-left origin at the primary display.
        let mouse = NSEvent.mouseLocation
        let hit = ElementHitTester.hit(at: CGPoint(x: mouse.x, y: primaryHeight - mouse.y))
        // Chrome hit-tests web content asynchronously: the first query at a point returns the page
        // (AXWebArea, or AXScrollArea before its tree exists) and a repeat ~150ms later returns the
        // element. Ask once more if the cursor is still there.
        if let role = hit?.role, role == "AXWebArea" || role == "AXScrollArea" {
            let work = DispatchWorkItem { [weak self] in
                guard let self, NSEvent.mouseLocation == mouse else { return }
                self.updateHighlightOnce()
            }
            refineHit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        apply(hit)
    }

    /// One hit test with no follow-up, so a page that really is the deepest element doesn't loop.
    private func updateHighlightOnce() {
        guard isActive else { return }
        let mouse = NSEvent.mouseLocation
        apply(ElementHitTester.hit(at: CGPoint(x: mouse.x, y: primaryHeight - mouse.y)))
    }

    private func apply(_ hit: ElementHitTester.Hit?) {
        for window in windows {
            guard let view = window.contentView as? OverlayView else { continue }
            view.highlight = hit.map { hit in
                let f = window.frame
                let local = hit.rect.offsetBy(dx: -f.minX, dy: -(primaryHeight - f.maxY))
                return (local, hit.role)
            }
        }
    }

    func end() {
        guard isActive else { return }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        refineHit?.cancel()
        refineHit = nil
        removeTap()
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        windows.removeAll()
        onCapture = { _, _ in }
    }
}
