import AppKit
import SwiftUI
import KiriCore

private final class GridPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What's layered over the grid: the note panel, then the enlarged capture.
@MainActor
final class GridState: ObservableObject {
    /// The capture whose note panel is open.
    @Published var noteShotID: UUID?
    /// The enlarged capture; the others sit in a stack to its right.
    @Published var zoomedID: UUID?
    let dictation: SpeechDictation

    init(dictation: SpeechDictation) {
        self.dictation = dictation
    }

    func closeNote() {
        dictation.stop()  // the final transcription still lands in the note
        noteShotID = nil
    }

    /// Esc and a background click close the top layer: the note panel, then the enlarged capture.
    /// Returns false when only the grid itself is left to close.
    func closeTopLayer() -> Bool {
        if noteShotID != nil {
            closeNote()
        } else if zoomedID != nil {
            zoomedID = nil
        } else {
            return false
        }
        return true
    }

    func reset() {
        closeNote()
        zoomedID = nil
    }
}

/// Full-screen view of every capture, laid out as a centered grid on the screen under the mouse.
/// Esc and a background click close the note panel, then the enlarged capture, then the grid; the
/// "show all" shortcut closes it outright.
@MainActor
final class GridController {
    private let model: AppModel
    private var panel: GridPanel?
    private var keyMonitor: Any?
    private let dictation = SpeechDictation()
    private let state: GridState

    init(model: AppModel) {
        self.model = model
        state = GridState(dictation: dictation)
    }

    func toggle() {
        if panel == nil { show() } else { hide() }
    }

    func show() {
        guard panel == nil,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main
        else { return }
        let panel = GridPanel(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel  // above the shelf (.floating)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The Dock and menu bar sit above this panel; keep the grid and its controls out of them.
        let f = screen.frame, v = screen.visibleFrame
        panel.contentView = NSHostingView(rootView: GridView(
            model: model,
            dictation: dictation,
            state: state,
            insets: EdgeInsets(top: f.maxY - v.maxY, leading: v.minX - f.minX,
                               bottom: v.minY - f.minY, trailing: f.maxX - v.maxX),
            onClose: { [weak model] id in
                model?.remove(id)
                Sounds.playDelete()
            },
            onDismiss: { [weak self] in self?.hide() },
            onSave: { [weak self] in self?.saveAll() }))
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, self.panel?.isKeyWindow == true else { return event }
            var closedLayer = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { closedLayer = self.state.closeTopLayer() }
            if !closedLayer { self.hide() }
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Asks for a folder in a Finder panel and writes every capture there as `kiri-N.png`, plus
    /// `kiri-notes.md` if any capture has a note. Asks before replacing files of those names.
    /// Returns the pill's result message, or nil if cancelled.
    func saveAll() -> String? {
        let shots = model.shots
        guard !shots.isEmpty else { return nil }
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Save"
        open.message = "Choose a folder for \(shots.count) capture\(shots.count == 1 ? "" : "s")"
        open.level = .modalPanel + 1  // above the grid
        defer { panel?.makeKeyAndOrderFront(nil) }  // so Esc reaches the grid again
        guard open.runModal() == .OK, let dir = open.url else { return nil }

        let names = Clipboard.exportNames(shots)
        let existing = names.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Replace \(existing.count) existing file\(existing.count == 1 ? "" : "s") in “\(dir.lastPathComponent)”?"
            alert.informativeText = existing.joined(separator: ", ")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.window.level = .modalPanel + 1
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        guard let (urls, notesURL) = Clipboard.export(shots, to: dir) else { return "Save failed" }
        return "Saved \(urls.count) file\(urls.count == 1 ? "" : "s")\(notesURL == nil ? "" : " + notes")"
    }

    func hide() {
        state.reset()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private struct GridView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: SpeechDictation
    @ObservedObject var state: GridState
    /// Menu bar / Dock areas of the screen, which cover this panel.
    var insets: EdgeInsets
    var onClose: (UUID) -> Void
    var onDismiss: () -> Void
    /// Saves every capture to a folder the user picks; returns the result message, or nil if cancelled.
    var onSave: () -> String?
    @State private var hoveredID: UUID?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            content.padding(insets)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: backgroundTap)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shots.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.zoomedID)
    }

    private var content: some View {
        GeometryReader { geo in
            let layout = KiriCore.GridLayout.arrange(model.shots.map(\.image.size), in: geo.size)
            let placed: [(shot: Shot, tile: KiriCore.GridLayout.Tile)] = Array(zip(model.shots, layout.tiles))
            ZStack {
                if model.shots.isEmpty {
                    Text("No captures yet")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                } else if let focus = model.shots.firstIndex(where: { $0.id == state.zoomedID }) {
                    zoomed(focus, in: geo.size)
                } else {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            ForEach(placed, id: \.shot.id) { p in
                                tile(p.shot, p.tile)
                            }
                        }
                        .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
                        .padding(GridLayout.padding)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: backgroundTap)  // tiles handle their own taps
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !model.shots.isEmpty {
                    // Anchored at the bottom, so the note panel grows upward as its text does.
                    VStack(spacing: 12) {
                        if let id = state.noteShotID {
                            NotePanel(dictation: dictation,
                                      text: Binding(get: { model.shots.first { $0.id == id }?.note ?? "" },
                                                    set: { model.setNote(id, $0) }),
                                      onMic: { toggleListening(id) },
                                      onDone: state.closeNote)
                                .id(id)  // a fresh panel (and text focus) per capture
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        HStack(spacing: 10) {
                            copyButton(.all, title: "Copy All", icon: "doc.on.doc.fill",
                                       help: "Copy every capture as PNG files. ⇧-click to copy their paths as text.")
                            copyButton(.agent, title: "Copy for Agent", icon: "terminal.fill",
                                       help: "Copy the paths of every capture as text, for pasting into a terminal agent.")
                            pillButton(.save, title: "Save…", icon: "square.and.arrow.down.fill",
                                       help: "Save every capture as PNG files (and notes) to a folder you choose.",
                                       action: onSave)
                        }
                    }
                    .padding(.bottom, 14)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.noteShotID)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private enum PillButton { case all, agent, save }

    /// Which pill last ran, and its result message, shown in place of its title for ~1.3s.
    @State private var copyResult: (button: PillButton, message: String)?
    @State private var copyToken = 0

    private func copyButton(_ button: PillButton, title: String, icon: String, help: String) -> some View {
        pillButton(button, title: title, icon: icon, help: help) {
            let asPaths = button == .agent || NSEvent.modifierFlags.contains(.shift)
            let n = model.shots.count
            let noun = asPaths ? "path" : "file"
            let hasNotes = model.shots.contains { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let ok = Clipboard.copyAll(model.shots, as: asPaths ? .paths : .files)
            if ok { Sounds.playCopy() }
            return ok ? "Copied \(n) \(noun)\(n == 1 ? "" : "s")\(hasNotes ? " + notes" : "")" : "Copy failed"
        }
    }

    /// A bottom pill whose action returns a result message to show in its place, or nil to show nothing.
    private func pillButton(_ button: PillButton, title: String, icon: String, help: String,
                            action: @escaping () -> String?) -> some View {
        let result = copyResult?.button == button ? copyResult?.message : nil
        return Button {
            guard let message = action() else { return }
            copyResult = (button, message)
            copyToken += 1
            let token = copyToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if token == copyToken { copyResult = nil }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: result == nil ? icon : "checkmark.circle.fill")
                Text(result ?? title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.7)))
            .overlay(Capsule().strokeBorder(ShotCardView.borderColor.opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The enlarged capture on the left, the others in a left-aligned stack to its right. Long content
    /// (a full-page capture) scrolls; so does a stack too tall for the screen.
    private func zoomed(_ focus: Int, in size: CGSize) -> some View {
        let z = KiriCore.GridLayout.zoomed(model.shots.map(\.image.size), focus: focus, in: size)
        let stacked: [(shot: Shot, tile: KiriCore.GridLayout.Tile)] = Array(zip(z.stackIndices.map { model.shots[$0] }, z.stack))
        // Room around scrolling content for hover scale and shadows, which a scroll view would clip.
        let bleed: CGFloat = 12
        return ZStack(alignment: .topLeading) {
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    tile(model.shots[focus], z.main, enlarged: true)
                }
                .frame(width: z.main.frame.width, height: z.main.frame.height, alignment: .topLeading)
            }
            .scrollDisabled(!z.mainScrolls)
            .frame(width: z.mainViewport.width, height: z.mainViewport.height)
            .position(x: z.mainViewport.midX, y: z.mainViewport.midY)
            .id(model.shots[focus].id)  // start a newly enlarged capture at its top
            .transition(.opacity)

            if !stacked.isEmpty {
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        ForEach(stacked, id: \.shot.id) { p in
                            tile(p.shot, p.tile)
                        }
                    }
                    .frame(width: z.stackFrame.width, height: z.stackContentHeight, alignment: .topLeading)
                    .padding(bleed)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: backgroundTap)  // tiles handle their own taps
                }
                .scrollDisabled(z.stackContentHeight <= z.stackFrame.height)
                .frame(width: z.stackFrame.width + 2 * bleed, height: z.stackFrame.height + 2 * bleed)
                .position(x: z.stackFrame.midX, y: z.stackFrame.midY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// One capture at its layout size. A compact tile (too small for its controls) gets them in a
    /// bar below the image; the bar is part of the tile's hover area. The enlarged capture doesn't
    /// grow on hover, and always shows its zoom button (to go back to the grid).
    private func tile(_ shot: Shot, _ t: KiriCore.GridLayout.Tile, enlarged: Bool = false) -> some View {
        let hovered = hoveredID == shot.id
        let corner = min(8, t.imageSize.height / 2, t.imageSize.width / 2)
        let controls = HStack(spacing: 6) {
            zoomButton(shot, hovered: hovered)
            noteButton(shot, hovered: hovered)
        }
        return VStack(spacing: GridLayout.barGap) {
            ShotCardView(shot: shot, size: t.imageSize, cornerRadius: corner, hovered: hovered, edge: nil,
                         hoverScale: enlarged ? 1 : ShotCardView.defaultHoverScale,
                         accessory: t.compact ? nil : AnyView(controls),
                         showsControls: !t.compact,
                         onClose: { onClose(shot.id) })
                .frame(width: t.imageSize.width, height: t.imageSize.height)
            if t.compact {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    controls
                    if hovered { ShotCardView.closeButton { onClose(shot.id) }.transition(.opacity) }
                }
                .frame(height: GridLayout.barHeight)
                .animation(.easeOut(duration: 0.15), value: hovered)
            }
        }
        .frame(width: t.frame.width, height: t.frame.height, alignment: .top)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredID = shot.id } else if hoveredID == shot.id { hoveredID = nil }
        }
        .onTapGesture { ShotCardView.copyNotifier.send(shot.id) }
        .position(x: t.frame.midX, y: t.frame.midY)
        .zIndex(hovered || state.noteShotID == shot.id ? 1 : 0)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    /// Shown on hover, and always on the enlarged capture. Enlarges this capture (only one at a time),
    /// or on the enlarged one, goes back to the grid.
    @ViewBuilder
    private func zoomButton(_ shot: Shot, hovered: Bool) -> some View {
        let zoomed = state.zoomedID == shot.id
        if hovered || zoomed {
            roundButton(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: zoomed ? "Back to the grid" : "Enlarge") {
                state.zoomedID = zoomed ? nil : shot.id
            }
        }
    }

    // MARK: Notes

    /// Shown on hover, or always once the capture has a note. Opens the note panel ready to type;
    /// dictation starts only from the panel's Dictate button.
    @ViewBuilder
    private func noteButton(_ shot: Shot, hovered: Bool) -> some View {
        let hasNote = !shot.note.isEmpty
        let open = state.noteShotID == shot.id
        if hovered || hasNote || open {
            roundButton(hasNote ? "text.bubble.fill" : "mic.fill",
                        help: hasNote ? shot.note : "Dictate changes for the agent") {
                if open { state.closeNote() } else { openNote(shot.id) }
            }
        }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.black.opacity(0.6)))
                .overlay(Circle().strokeBorder(ShotCardView.borderColor.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .transition(.opacity)
    }

    /// A background click closes the note panel if it's open (as the popover did), then the enlarged
    /// capture, then the grid; the same order as Esc.
    private func backgroundTap() {
        if !state.closeTopLayer() { onDismiss() }
    }

    private func openNote(_ id: UUID) {
        state.closeNote()
        state.noteShotID = id
    }

    /// Dictation appends to whatever the note already says.
    private func toggleListening(_ id: UUID) {
        if dictation.isBusy { return dictation.stop() }
        let base = model.shots.first { $0.id == id }?.note ?? ""
        Sounds.playDictate()
        dictation.start { [weak model] spoken in
            let sep = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
            model?.setNote(id, base + sep + spoken)
        }
    }
}

/// One capture's note, shown at the bottom center above the copy buttons. Text first: it opens with
/// the cursor in the text box, and Dictate (top right) starts the mic. While listening, the status row
/// shows a red dot, live mic waveform and Stop, and the box is read-only as the transcription writes
/// into it; typing focus returns when dictation finishes.
private struct NotePanel: View {
    @ObservedObject var dictation: SpeechDictation
    @Binding var text: String
    var onMic: () -> Void
    var onDone: () -> Void
    @FocusState private var textFocused: Bool

    private static let width: CGFloat = 420
    private static let red = Color(red: 0.89, green: 0.19, blue: 0.19)
    private static let secondary = Color.black.opacity(0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField(dictation.isListening ? "Start speaking…" : "Type or dictate changes for the agent",
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1...8)
                .disabled(dictation.isBusy)  // the transcription is writing into it
                .focused($textFocused)
                .onAppear { textFocused = true }
                .onChange(of: dictation.isBusy) { _, busy in if !busy { textFocused = true } }
                .padding(.horizontal, 14).padding(.vertical, 12)
                // #F7F7F7 with an inner shadow: x 0, y 0, blur 1, black 25%.
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ShotCardView.borderColor.shadow(.inner(color: .black.opacity(0.25), radius: 1, x: 0, y: 0))))
            if let error = dictation.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture {}  // clicks in the panel don't reach the background (which would close it)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dictation.isListening ? Self.red : Color.black.opacity(0.25))
                .frame(width: 14, height: 14)
            Text(dictation.isListening ? "Capturing audio" : dictation.isBusy ? "Finishing…" : "Note")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.secondary)
            if dictation.isListening {
                LevelBars(levels: dictation.levels, color: Self.red)
            }
            Spacer(minLength: 8)
            if dictation.isListening {
                textButton("Stop", help: "Stop dictating", action: onMic)
            } else {
                textButton("Dictate", help: "Dictate more; it's added to the end", action: onMic)
                    .disabled(dictation.isBusy)
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Self.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close the note")
            }
        }
    }

    private func textButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(Self.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Live microphone level: one bar per recent sample, newest on the right.
private struct LevelBars: View {
    var levels: [Float]
    var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(color.opacity(0.75))
                    .frame(width: 2, height: 3 + CGFloat(levels[i]) * 15)
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.05), value: levels)
    }
}
