import AppKit
import SwiftUI
import KiriCore

private final class GridPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What's layered over the grid: the open comment, the active note, comment mode, then the enlarged
/// capture.
@MainActor
final class GridState: ObservableObject {
    /// Comment mode (C): clicking a capture pins a comment there instead of copying it.
    @Published var commenting = false
    /// The comment whose floating editor is open beside its pin.
    @Published var commentID: UUID?
    /// The capture whose sidebar note is being typed in or dictated into; its image gets a red border.
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

    func toggleCommenting() {
        commenting.toggle()
        if !commenting { commentID = nil }
    }

    /// Esc and a background click close the top layer: the open comment, the active note, comment
    /// mode, then the enlarged capture. Returns false when only the grid itself is left to close.
    func closeTopLayer() -> Bool {
        if commentID != nil {
            commentID = nil
        } else if noteShotID != nil {
            closeNote()
        } else if commenting {
            commenting = false
        } else if zoomedID != nil {
            zoomedID = nil
        } else {
            return false
        }
        return true
    }

    func reset() {
        closeNote()
        commenting = false
        commentID = nil
        zoomedID = nil
    }
}

/// Full-screen view of every capture, laid out as a centered grid on the screen under the mouse, with
/// a notes sidebar on the right. C toggles comment mode. Esc and a background click close the open
/// comment, the active note, comment mode, the enlarged capture, then the grid; the "show all"
/// shortcut closes it outright.
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
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 {  // Esc
                var closedLayer = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { closedLayer = self.state.closeTopLayer() }
                if !closedLayer { self.hide() }
                return nil
            }
            // C toggles comment mode, unless it's being typed into a note or comment.
            if event.charactersIgnoringModifiers?.lowercased() == "c",
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               !(panel.firstResponder is NSText), !self.model.shots.isEmpty {
                withAnimation(.easeOut(duration: 0.15)) { self.state.toggleCommenting() }
                return nil
            }
            return event
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
        model.removeEmptyComments(keeping: [])
        NSCursor.arrow.set()  // in case it closed over a capture with the comment cursor
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
    /// The sidebar note with the text cursor.
    @FocusState private var focusedNote: UUID?
    /// The comment field with the text cursor: the floating editor by a pin, or a sidebar row.
    @FocusState private var focusedComment: CommentField?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            HStack(spacing: 0) {
                content
                if !model.shots.isEmpty {
                    sidebar
                        .padding(.vertical, 24).padding(.trailing, 24)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(insets)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: backgroundTap)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shots.map(\.id))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: state.zoomedID)
        .overlayPreferenceValue(PinAnchorKey.self, commentEditor)
        .onChange(of: state.commentID) { _, _ in pruneComments() }
        .onChange(of: focusedComment) { _, field in
            // A sidebar comment makes its capture's card the active note, like typing in the note.
            if case .sidebar(let id)? = field,
               let shotID = model.shots.first(where: { $0.comments.contains { $0.id == id } })?.id {
                if state.noteShotID != shotID { state.closeNote() }
                state.noteShotID = shotID
            } else if focusedNote == nil, !dictation.isBusy {
                state.noteShotID = nil
            }
            pruneComments()
        }
        .onChange(of: state.commenting) { _, on in if !on { NSCursor.arrow.set() } }
    }

    /// Removes empty comments once nothing is editing them: not the open editor, not a sidebar row
    /// with the text cursor.
    private func pruneComments() {
        var keep = Set<UUID>()
        if let id = state.commentID { keep.insert(id) }
        if case .sidebar(let id)? = focusedComment { keep.insert(id) }
        model.removeEmptyComments(keeping: keep)
    }

    /// The open comment's text field, floating to the right of its pin (or to the left when there's no
    /// room before the sidebar). Return or Esc closes it; an empty comment is then removed.
    @ViewBuilder
    private func commentEditor(_ anchors: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let id = state.commentID, let anchor = anchors[id], model.comment(id) != nil {
                let pin = proxy[anchor]
                let gap: CGFloat = 8
                let limit = proxy.size.width - insets.trailing - NoteCard.sidebarWidth - 24
                let x = pin.maxX + gap + CommentEditor.width <= limit ? pin.maxX + gap : pin.minX - gap - CommentEditor.width
                CommentEditor(id: id, text: commentText(id), focus: $focusedComment,
                              onDone: { state.commentID = nil })
                    .id(id)
                    .offset(x: x, y: pin.minY)
                    .transition(.opacity)
            }
        }
    }

    private func commentText(_ id: UUID) -> Binding<String> {
        Binding(get: { model.comment(id)?.text ?? "" }, set: { model.setComment(id, $0) })
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
                    VStack(spacing: 10) {
                        if state.commenting {
                            Text("Click a capture to comment · C or Esc to stop")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.85))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(.white))
                                .transition(.opacity)
                        }
                        HStack(spacing: 10) {
                            pillButton(.all, title: "Copy All", icon: "doc.on.doc.fill",
                                       help: "Copy every capture as PNG files. ⇧-click to copy their paths as text.") {
                                copyAll(asPaths: NSEvent.modifierFlags.contains(.shift))
                            }
                            pillButton(.save, title: "Save…", icon: "square.and.arrow.down.fill",
                                       help: "Save every capture as PNG files (and notes) to a folder you choose.",
                                       action: onSave)
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private enum PillButton { case all, agent, save }

    /// Which pill last ran, and its result message, shown in place of its title for ~1.3s.
    @State private var copyResult: (button: PillButton, message: String)?
    @State private var copyToken = 0

    /// Copies every capture (Copy All, Copy to Agent) and returns the result message.
    private func copyAll(asPaths: Bool) -> String {
        let n = model.shots.count
        let noun = asPaths ? "path" : "file"
        let hasNotes = model.shots.contains { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ok = Clipboard.copyAll(model.shots, as: asPaths ? .paths : .files)
        if ok { Sounds.playCopy() }
        return ok ? "Copied \(n) \(noun)\(n == 1 ? "" : "s")\(hasNotes ? " + notes" : "")" : "Copy failed"
    }

    /// Runs a button's action and shows its result message in place of its title for ~1.3s.
    private func runShowingResult(_ button: PillButton, _ action: () -> String?) {
        guard let message = action() else { return }
        copyResult = (button, message)
        copyToken += 1
        let token = copyToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if token == copyToken { copyResult = nil }
        }
    }

    /// A bottom pill whose action returns a result message to show in its place, or nil to show nothing.
    private func pillButton(_ button: PillButton, title: String, icon: String, help: String,
                            action: @escaping () -> String?) -> some View {
        let result = copyResult?.button == button ? copyResult?.message : nil
        return Button {
            runShowingResult(button, action)
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
        let controls = zoomButton(shot, hovered: hovered)
        let commenting = state.commenting
        return VStack(spacing: GridLayout.barGap) {
            // In comment mode the card doesn't grow on hover, so a click lands where the pin will show.
            ShotCardView(shot: shot, size: t.imageSize, cornerRadius: corner, hovered: hovered, edge: nil,
                         hoverScale: enlarged || commenting ? 1 : ShotCardView.defaultHoverScale,
                         highlight: state.noteShotID == shot.id ? NoteCard.red : nil,
                         accessory: t.compact ? nil : AnyView(controls),
                         showsControls: !t.compact,
                         showsClose: !commenting,
                         onClose: { onClose(shot.id) })
                .frame(width: t.imageSize.width, height: t.imageSize.height)
                .gesture(SpatialTapGesture().onEnded { addComment(shot.id, at: $0.location, in: t.imageSize) },
                         including: commenting ? .all : .subviews)
                .onContinuousHover { phase in
                    guard state.commenting else { return }
                    switch phase {
                    case .active: CommentCursor.shared.set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
                .overlay(alignment: .topLeading) {
                    if commenting { pins(shot, in: t.imageSize) }
                }
            if t.compact {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    controls
                    if hovered && !commenting { ShotCardView.closeButton { onClose(shot.id) }.transition(.opacity) }
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
        .onTapGesture { if !state.commenting { ShotCardView.copyNotifier.send(shot.id) } }
        .position(x: t.frame.midX, y: t.frame.midY)
        .zIndex(hovered || state.noteShotID == shot.id || shot.comments.contains { $0.id == state.commentID } ? 1 : 0)
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

    // MARK: Comments

    /// Pins a new comment where the image was clicked and opens its editor.
    private func addComment(_ shotID: UUID, at p: CGPoint, in size: CGSize) {
        let point = CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
        withAnimation(.easeOut(duration: 0.15)) { state.commentID = model.addComment(to: shotID, at: point) }
    }

    /// The capture's comment pins (comment mode only), each with its bottom-left point on the spot
    /// that was clicked. Clicking a pin opens or closes its editor.
    private func pins(_ shot: Shot, in size: CGSize) -> some View {
        let numbers = model.commentNumbers
        return ZStack(alignment: .topLeading) {
            ForEach(shot.comments) { c in
                let open = state.commentID == c.id
                Button {
                    state.commentID = open ? nil : c.id
                } label: {
                    CommentPin(number: numbers[c.id] ?? 0, active: open)
                }
                .buttonStyle(.plain)
                .anchorPreference(key: PinAnchorKey.self, value: .bounds) { open ? [c.id: $0] : [:] }
                .position(x: c.point.x * size.width + CommentPin.size / 2,
                          y: c.point.y * size.height - CommentPin.size / 2)
                .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    // MARK: Notes

    /// One note card per capture, in shelf order, above Copy to Agent. Always shown while the grid is
    /// open; the cards scroll when they don't fit.
    private var sidebar: some View {
        let numbers = model.commentNumbers
        let cards = VStack(spacing: 16) {
            ForEach(Array(model.shots.enumerated()), id: \.element.id) { i, shot in
                NoteCard(name: "kiri-\(i + 1).png",
                         id: shot.id,
                         text: Binding(get: { model.shots.first { $0.id == shot.id }?.note ?? "" },
                                       set: { model.setNote(shot.id, $0) }),
                         dictation: dictation,
                         isActive: state.noteShotID == shot.id,
                         focus: $focusedNote,
                         comments: shot.comments.map { (numbers[$0.id] ?? 0, $0.id) },
                         openComment: state.commentID,
                         commentText: commentText,
                         commentFocus: $focusedComment,
                         onMic: { toggleListening(shot.id) })
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        let result = copyResult?.button == .agent ? copyResult?.message : nil
        return VStack(spacing: 16) {
            ViewThatFits(in: .vertical) {
                cards
                ScrollView(.vertical) { cards }
            }
            Button {
                runShowingResult(.agent) { copyAll(asPaths: true) }
            } label: {
                HStack(spacing: 6) {
                    if result != nil { Image(systemName: "checkmark.circle.fill") }
                    Text(result ?? "Copy to Agent")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(white: 0x55 / 255.0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy the paths of every capture as text, with their notes, for pasting into a terminal agent.")
        }
        .padding(16)
        .frame(width: NoteCard.sidebarWidth)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .onTapGesture {}  // clicks in the sidebar don't reach the background (which would close the grid)
        .frame(maxHeight: .infinity, alignment: .top)
        // The active note follows the text cursor, and stays on a capture while it's being dictated into.
        .onChange(of: focusedNote) { _, id in
            if let id {
                if state.noteShotID != id { state.closeNote() }
                state.noteShotID = id
            } else if !dictation.isBusy, !focusedComment.isSidebar {
                state.noteShotID = nil
            }
        }
        .onChange(of: state.noteShotID) { _, id in
            if id == nil {
                focusedNote = nil
                if focusedComment.isSidebar { focusedComment = nil }
            }
        }
        .onChange(of: dictation.isBusy) { _, busy in
            if !busy, let id = state.noteShotID { focusedNote = id }  // back to typing after dictation
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

    /// A background click ends the active note, then the enlarged capture, then the grid; the same
    /// order as Esc.
    private func backgroundTap() {
        if !state.closeTopLayer() { onDismiss() }
    }

    /// Dictation appends to whatever the note already says.
    private func toggleListening(_ id: UUID) {
        if dictation.isBusy { return dictation.stop() }
        state.noteShotID = id
        focusedNote = nil  // the box is read-only while dictating; focus returns when it finishes
        let base = model.shots.first { $0.id == id }?.note ?? ""
        Sounds.playDictate()
        dictation.start { [weak model] spoken in
            let sep = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
            model?.setNote(id, base + sep + spoken)
        }
    }
}

/// One capture's note in the sidebar: its file name, Dictate, and the text box. While this card is
/// dictating, Dictate becomes a live mic waveform and Stop, and the box is read-only as the
/// transcription writes into it.
private struct NoteCard: View {
    let name: String
    let id: UUID
    @Binding var text: String
    @ObservedObject var dictation: SpeechDictation
    /// Being typed in or dictated into.
    let isActive: Bool
    var focus: FocusState<UUID?>.Binding
    /// This capture's comments with their numbers, as editable rows under the note.
    let comments: [(number: Int, id: UUID)]
    /// The comment whose editor is open in the grid; its row's pin shows the open state.
    let openComment: UUID?
    var commentText: (UUID) -> Binding<String>
    var commentFocus: FocusState<CommentField?>.Binding
    var onMic: () -> Void

    static let sidebarWidth: CGFloat = 300
    static let red = Color(red: 0.89, green: 0.19, blue: 0.19)
    private static let secondary = Color.black.opacity(0.5)
    private static let stroke = Color.black.opacity(0.12)

    private var listening: Bool { isActive && dictation.isListening }
    private var busy: Bool { isActive && dictation.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField(listening ? "Start speaking…" : "Type or dictate changes for the agent",
                      text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(.black.opacity(0.85))
                .lineLimit(1...8)
                .disabled(busy)  // the transcription is writing into it
                .focused(focus, equals: id)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ShotCardView.borderColor))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.stroke, lineWidth: 1))
            ForEach(comments, id: \.id) { c in
                HStack(alignment: .top, spacing: 8) {
                    CommentPin(number: c.number, active: openComment == c.id)
                    TextField("Comment", text: commentText(c.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(1...6)
                        .focused(commentFocus, equals: .sidebar(c.id))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(minHeight: CommentPin.size)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ShotCardView.borderColor))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Self.stroke, lineWidth: 1))
                }
                .transition(.opacity)
            }
            if isActive, let error = dictation.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Self.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.stroke, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.secondary)
                .lineLimit(1)
            if listening {
                LevelBars(levels: dictation.levels, color: Self.red)
            }
            Spacer(minLength: 8)
            if listening {
                textButton("Stop", help: "Stop dictating", action: onMic)
            } else if busy {
                Text("Finishing…").font(.system(size: 13)).foregroundStyle(Self.secondary)
            } else {
                textButton("Dictate", help: "Dictate changes for the agent; it's added to the end", action: onMic)
                    .disabled(dictation.isBusy)  // one dictation at a time
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

/// Which comment field has the text cursor: the floating editor by a pin, or the comment's sidebar row.
private enum CommentField: Hashable {
    case pin(UUID)
    case sidebar(UUID)
}

private extension Optional where Wrapped == CommentField {
    var isSidebar: Bool { if case .sidebar? = self { return true } else { return false } }
}

/// The open comment's pin bounds, so the editor can float beside it above everything else.
private struct PinAnchorKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A numbered comment pin: a circle with a square bottom-left corner that points at the comment's
/// spot. Dark while its editor is open.
private struct CommentPin: View {
    let number: Int
    var active = false
    static let size: CGFloat = 24
    private static let ink = Color(white: 0.12)

    var body: some View {
        let r = Self.size / 2
        let shape = UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: r, topTrailingRadius: r, style: .circular)
        Text("\(number)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .minimumScaleFactor(0.6)
            .foregroundStyle(active ? .white : Self.ink)
            .frame(width: Self.size, height: Self.size)
            .background(shape.fill(active ? Self.ink : .white))
            .overlay(shape.strokeBorder(active ? .white : Self.ink, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .contentShape(shape)
    }
}

/// The floating text field for a comment, beside its pin. It takes the text cursor when it opens.
private struct CommentEditor: View {
    let id: UUID
    @Binding var text: String
    var focus: FocusState<CommentField?>.Binding
    var onDone: () -> Void
    static let width: CGFloat = 260

    var body: some View {
        TextField("Add a comment", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.black.opacity(0.85))
            .lineLimit(1...8)
            .focused(focus, equals: .pin(id))
            .onSubmit(onDone)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .environment(\.colorScheme, .light)
            .contentShape(Rectangle())
            .onTapGesture {}  // clicks here don't reach the background (which would close it)
            .onAppear { DispatchQueue.main.async { focus.wrappedValue = .pin(id) } }
    }
}

/// The cursor over a capture in comment mode: the pin's outline with a +, pointing from its
/// bottom-left corner.
private enum CommentCursor {
    @MainActor static let shared: NSCursor = {
        let s: CGFloat = 24
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            func pin(_ r: NSRect) {
                NSBezierPath(ovalIn: r).fill()
                NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height / 2).fill()
            }
            NSColor.black.setFill()
            pin(NSRect(x: 1, y: 1, width: 22, height: 22))
            NSColor.white.setFill()
            pin(NSRect(x: 2.5, y: 2.5, width: 19, height: 19))
            NSColor.black.setFill()
            NSRect(x: 11.25, y: 8, width: 1.5, height: 8).fill()
            NSRect(x: 8, y: 11.25, width: 8, height: 1.5).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 1, y: 23))  // top-left origin: the bottom-left tip
    }()
}
