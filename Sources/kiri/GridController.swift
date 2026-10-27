import AppKit
import SwiftUI
import KiriCore

private final class GridPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The collection's view, selection and what's layered over it: the open comment, the sidebar field
/// being edited, then comment mode.
@MainActor
final class GridState: ObservableObject {
    enum Mode { case single, all }
    /// Single View (one large preview) or All images (every capture in a grid).
    @Published var mode = Mode.single
    /// The capture in the preview; its sidebar card is the active one. Nil means the first capture.
    @Published var selectedID: UUID?
    /// Comment mode (C): clicking the preview pins a comment there instead of copying it.
    @Published var commenting = false
    /// The comment whose floating editor is open beside its pin.
    @Published var commentID: UUID?
    /// A sidebar note or comment row has the text cursor, or a note is being dictated into.
    @Published var editing = false
    let dictation: SpeechDictation

    init(dictation: SpeechDictation) {
        self.dictation = dictation
    }

    /// Shows a capture in the preview. Moving to another capture stops any dictation (the final
    /// transcription still lands in the note it started in) and closes the open comment.
    func select(_ id: UUID) {
        guard id != selectedID else { return }
        dictation.stop()
        commentID = nil
        selectedID = id
    }

    /// The previous (−1) or next (+1) capture, if there is one.
    func step(_ delta: Int, in ids: [UUID]) {
        let i = ids.firstIndex { $0 == selectedID } ?? 0
        if ids.indices.contains(i + delta) { select(ids[i + delta]) }
    }

    func stopEditing() {
        dictation.stop()  // the final transcription still lands in the note
        editing = false
    }

    /// Comment mode works on the preview, so turning it on switches to Single View.
    func toggleCommenting() {
        commenting.toggle()
        if commenting { mode = .single } else { commentID = nil }
    }

    /// Esc and a background click close the top layer: the open comment, the field being edited, then
    /// comment mode. Returns false when only the collection itself is left to close.
    func closeTopLayer() -> Bool {
        if commentID != nil {
            commentID = nil
        } else if editing {
            stopEditing()
        } else if commenting {
            commenting = false
        } else {
            return false
        }
        return true
    }

    /// Closing the collection ends editing and comment mode; the view and selection stay for next time.
    func reset() {
        stopEditing()
        commenting = false
        commentID = nil
    }
}

/// "Your collection": a full-screen view of every capture with a notes sidebar on the right. Single
/// View shows one capture large (click it to copy) above a strip of thumbnails; All images shows them
/// all in a grid. C toggles comment mode, ← → step through captures, and Esc closes the open comment,
/// the field being edited, comment mode, then the collection; the "show all" shortcut closes it outright.
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
        // The panel dims the whole screen; the collection is a card at 80% of the area between the
        // menu bar and Dock, centered (in the panel's top-left coordinates).
        let f = screen.frame, v = screen.visibleFrame
        let card = v.insetBy(dx: v.width * 0.1, dy: v.height * 0.1)
        let panel = GridPanel(contentRect: f, styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .modalPanel  // above the shelf (.floating)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ZStack {
            Color.black.opacity(0.4)
                .onTapGesture { [weak self] in self?.hide() }
            GridView(
                model: model,
                dictation: dictation,
                state: state,
                onClose: { [weak model] id in
                    model?.remove(id)
                    Sounds.playDelete()
                },
                onSave: { [weak self] in self?.saveAll() })
                .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                .frame(width: card.width, height: card.height)
                .position(x: card.midX - f.minX, y: f.maxY - card.midY)
        })
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }
            if event.keyCode == 53 {  // Esc
                var closedLayer = false
                withAnimation(.easeOut(duration: 0.15)) { closedLayer = self.state.closeTopLayer() }
                if !closedLayer { self.hide() }
                return nil
            }
            // C and ← → work unless a note or comment is being typed into.
            guard !(panel.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !self.model.shots.isEmpty
            else { return event }
            if event.charactersIgnoringModifiers?.lowercased() == "c" {
                withAnimation(.easeOut(duration: 0.15)) { self.state.toggleCommenting() }
                return nil
            }
            if (event.keyCode == 123 || event.keyCode == 124), self.state.mode == .single {  // ← →
                self.state.step(event.keyCode == 123 ? -1 : 1, in: self.model.shots.map(\.id))
                return nil
            }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Asks for a folder in a Finder panel and writes every capture there as `kiri-N.png`, plus
    /// `kiri-notes.md` if any capture has a note. Asks before replacing files of those names.
    /// Returns the button's result message, or nil if cancelled.
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
        open.level = .modalPanel + 1  // above the collection
        defer { panel?.makeKeyAndOrderFront(nil) }  // so Esc reaches the collection again
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
        NSCursor.arrow.set()  // in case it closed over the preview with the comment cursor
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

/// The collection's colors, light and dark, following the system appearance.
private enum Palette {
    static let bg = dynamic(0xFFFFFF, 0x161616)
    static let text = dynamic(0x1D1D1F, 0xEDEDED)
    /// Pill and segment titles.
    static let label = dynamic(0x403F3F, 0xD8D8D8)
    /// Note card titles and the "Comments" heading.
    static let subtle = dynamic(0x4F4F4F, 0xB8B8B8)
    static let muted = dynamic(0x717171, 0xA0A0A0)
    static let line = dynamic(0xE5E5E5, 0x2E2E2E)
    static let pill = dynamic(0xFFFFFF, 0x262626)
    static let pillHover = dynamic(0xFAFAFA, 0x313131)
    static let pillBorder = dynamic(0x222222, 0xFFFFFF, alpha: 0.07)
    static let track = dynamic(0xF5F4F4, 0x262626)
    static let stage = dynamic(0xF7F7F7, 0x222222)
    static let placeholder = dynamic(0xD0D0D0, 0x2C2C2C)
    static let thumbBorder = dynamic(0xCACACA, 0x3A3A3A)
    static let cardBorder = dynamic(0x222222, 0xFFFFFF, alpha: 0.15)
    static let accent = dynamic(0x0C5CF1, 0x6F97FF)
    /// The selected note card, its comments and Copy to Agent.
    static let purple = dynamic(0x5B21B6, 0xA78BFA)
    static let segmentOn = dynamic(0xFFFFFF, 0x3A3A3A)
    static let red = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let shadow = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x22 / 255)

    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
}

private extension Font {
    /// Bricolage Grotesque (`Resources/Fonts`, registered by `ATSApplicationFontsPath`) at a weight-axis
    /// value, optical size 14 as in the Figma. The system font when it isn't registered (bare executable).
    static func bricolage(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        let family = "Bricolage Grotesque"
        let axes: [UInt32: CGFloat] = [0x7767_6874: weight, 0x6F70_737A: 14, 0x7764_7468: 100]  // wght, opsz, wdth
        let attributes = [kCTFontFamilyNameAttribute as String: family, kCTFontVariationAttribute as String: axes] as CFDictionary
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes), size, nil)
        guard CTFontCopyFamilyName(font) as String == family else {
            return .system(size: size, weight: weight >= 500 ? .medium : .regular)
        }
        return Font(font)
    }
}

private struct GridView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: SpeechDictation
    @ObservedObject var state: GridState
    var onClose: (UUID) -> Void
    /// Saves every capture to a folder the user picks; returns the result message, or nil if cancelled.
    var onSave: () -> String?
    @State private var previewHovered = false
    @State private var hoveredTileID: UUID?
    /// The sidebar note with the text cursor.
    @FocusState private var focusedNote: UUID?
    /// The comment field with the text cursor: the floating editor by a pin, or a sidebar row.
    @FocusState private var focusedComment: CommentField?

    /// Side margins of the whole view, and the sidebar's width including its leading padding.
    static let margin: CGFloat = 20
    static let sidebarWidth: CGFloat = 360

    /// The capture in the preview.
    private var currentIndex: Int? {
        guard !model.shots.isEmpty else { return nil }
        return model.shots.firstIndex { $0.id == state.selectedID } ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.shots.isEmpty {
                Text("No captures yet")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    main
                        .padding(.top, 24).padding(.trailing, 24).padding(.bottom, 24)
                    Palette.line.frame(width: 1)
                    sidebar
                        .padding(.top, 24).padding(.leading, 24).padding(.bottom, 24)
                        .frame(width: Self.sidebarWidth)
                }
            }
        }
        .padding(.horizontal, Self.margin)
        .foregroundStyle(Palette.text)
        .background(Palette.bg.contentShape(Rectangle()).onTapGesture(perform: backgroundTap))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.shots.map(\.id))
        .overlayPreferenceValue(PinAnchorKey.self, commentEditor)
        .onChange(of: state.commentID) { _, _ in pruneComments() }
        .onChange(of: focusedNote) { _, id in
            if let id {
                state.select(id)
                state.editing = true
            } else if !dictation.isBusy, !focusedComment.isSidebar {
                state.editing = false
            }
        }
        .onChange(of: focusedComment) { _, field in
            // A sidebar comment selects its capture, like typing in its note.
            if case .sidebar(let id)? = field,
               let shotID = model.shots.first(where: { $0.comments.contains { $0.id == id } })?.id {
                state.select(shotID)
                state.editing = true
            } else if focusedNote == nil, !dictation.isBusy {
                state.editing = false
            }
            pruneComments()
        }
        .onChange(of: state.editing) { _, editing in
            if !editing {
                focusedNote = nil
                if focusedComment.isSidebar { focusedComment = nil }
            }
        }
        .onChange(of: dictation.isBusy) { _, busy in
            // Back to typing after dictation.
            if !busy, state.editing, let i = currentIndex { focusedNote = model.shots[i].id }
        }
        .onChange(of: state.commenting) { _, on in if !on { NSCursor.arrow.set() } }
    }

    /// A click on empty space closes the top layer (the same order as Esc), but never the collection.
    private func backgroundTap() {
        withAnimation(.easeOut(duration: 0.15)) { _ = state.closeTopLayer() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Text("Your collection")
                .font(.bricolage(20, weight: 500))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 16)
            HStack(spacing: 16) {
                HeaderPill(title: "Comment", on: state.commenting,
                           help: "Click the preview to pin a comment (C)") {
                    withAnimation(.easeOut(duration: 0.15)) { state.toggleCommenting() }
                }
                HeaderPill(title: result(.all) ?? "Copy all images",
                           help: "Copy every capture as PNG files. ⇧-click to copy their paths as text.") {
                    runShowingResult(.all) { copyAll(asPaths: NSEvent.modifierFlags.contains(.shift)) }
                }
                HeaderPill(title: result(.save) ?? "Save content…",
                           help: "Save every capture as PNG files (and notes) to a folder you choose.") {
                    runShowingResult(.save, onSave)
                }
            }
            .disabled(model.shots.isEmpty)
        }
        .padding(.top, 16).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Palette.line.frame(height: 1) }
    }

    private enum ResultButton { case all, agent, save }

    /// Which button last ran, and its result message, shown in place of its title for ~1.3s.
    @State private var copyResult: (button: ResultButton, message: String)?
    @State private var copyToken = 0

    private func result(_ button: ResultButton) -> String? {
        copyResult?.button == button ? copyResult?.message : nil
    }

    /// Copies every capture (Copy all images, Copy to Agent) and returns the result message.
    private func copyAll(asPaths: Bool) -> String {
        let n = model.shots.count
        let noun = asPaths ? "path" : "file"
        let hasNotes = model.shots.contains { !$0.context.isEmpty }
        let ok = Clipboard.copyAll(model.shots, as: asPaths ? .paths : .files)
        if ok { Sounds.playCopy() }
        return ok ? "Copied \(n) \(noun)\(n == 1 ? "" : "s")\(hasNotes ? " + notes" : "")" : "Copy failed"
    }

    /// Runs a button's action and shows its result message in place of its title for ~1.3s.
    private func runShowingResult(_ button: ResultButton, _ action: () -> String?) {
        guard let message = action() else { return }
        copyResult = (button, message)
        copyToken += 1
        let token = copyToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            if token == copyToken { copyResult = nil }
        }
    }

    // MARK: Main column

    private var main: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                segment("Single View", .single)
                segment("All images", .all)
            }
            .padding(4)
            .background(Capsule().fill(Palette.track))
            if state.mode == .single, let i = currentIndex {
                single(i)
            } else {
                all
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func segment(_ title: String, _ mode: GridState.Mode) -> some View {
        let on = state.mode == mode
        return Button {
            state.mode = mode
            if mode == .all, state.commenting { state.toggleCommenting() }
        } label: {
            Text(title)
                .font(.bricolage(12, weight: 500))
                .foregroundStyle(Palette.label)
                .padding(.horizontal, 16).frame(height: 24)
                .background(Capsule().fill(on ? Palette.segmentOn : .clear)
                    .shadow(color: .black.opacity(on ? 0.05 : 0), radius: 1.5, y: 2))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Single View

    /// The preview between ← and →, with the thumbnails and the file name under it.
    private func single(_ index: Int) -> some View {
        let shot = model.shots[index]
        let arrowWidth: CGFloat = 56, gap: CGFloat = 16
        return VStack(spacing: 28) {
            HStack(spacing: gap) {
                arrow("arrow.left", help: "Previous capture (←)", enabled: index > 0) {
                    state.select(model.shots[index - 1].id)
                }
                stage(shot)
                arrow("arrow.right", help: "Next capture (→)", enabled: index < model.shots.count - 1) {
                    state.select(model.shots[index + 1].id)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                thumbnails(current: index)
                Spacer(minLength: 0)
                Text("kiri-\(index + 1).png")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, arrowWidth + gap)
        }
    }

    private func arrow(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Palette.muted)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(HoverCircleStyle())
        .disabled(!enabled)
        .help(help)
    }

    /// The grey stage holding the preview: fitted, never upscaled; long captures scroll at fit-to-width.
    private func stage(_ shot: Shot) -> some View {
        GeometryReader { geo in
            let inset: CGFloat = 24
            let area = CGSize(width: geo.size.width - 2 * inset, height: geo.size.height - 2 * inset)
            let fit = KiriCore.GridLayout.preview(shot.image.size, in: area)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.stage)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: backgroundTap)
                if fit.scrolls {
                    ScrollView(.vertical) { preview(shot, size: fit.imageSize) }
                        .frame(width: fit.imageSize.width + 2 * inset, height: geo.size.height)
                } else {
                    preview(shot, size: fit.imageSize)
                }
            }
            .overlay(alignment: .bottom) {
                if state.commenting {
                    Text("Click the preview to comment · C or Esc to stop")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.bg)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Capsule().fill(Palette.text))
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
        }
        .id(shot.id)  // a newly shown capture starts at its top
    }

    /// The capture at its preview size. A click copies it, or in comment mode pins a comment there.
    private func preview(_ shot: Shot, size: CGSize) -> some View {
        let commenting = state.commenting
        return ShotCardView(shot: shot, size: size, cornerRadius: 4, hovered: previewHovered, edge: nil,
                            hoverScale: 1, showsClose: !commenting, onClose: { delete(shot.id) })
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .onHover { previewHovered = $0 }
            .onContinuousHover { phase in
                guard state.commenting else { return }
                switch phase {
                case .active: CommentCursor.shared.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .onTapGesture { location in
                if state.commenting {
                    addComment(shot.id, at: location, in: size)
                } else {
                    ShotCardView.copyNotifier.send(shot.id)
                }
            }
            .overlay(alignment: .topLeading) {
                if commenting { pins(shot, in: size) }
            }
            .padding(24)
    }

    /// Selects a neighbor before deleting the capture in the preview.
    private func delete(_ id: UUID) {
        if let i = model.shots.firstIndex(where: { $0.id == id }), i == currentIndex {
            let neighbor = i + 1 < model.shots.count ? i + 1 : i - 1
            if model.shots.indices.contains(neighbor) { state.select(model.shots[neighbor].id) }
        }
        onClose(id)
    }

    /// One 83×62 thumbnail per capture, five per row. A click selects (doesn't copy).
    private func thumbnails(current: Int) -> some View {
        let columns = Array(repeating: GridItem(.fixed(83), spacing: 12), count: 5)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(Array(model.shots.enumerated()), id: \.element.id) { i, shot in
                let slot = RoundedRectangle(cornerRadius: 4, style: .continuous)
                Button { state.select(shot.id) } label: {
                    Palette.placeholder
                        .frame(width: 83, height: 62)
                        .overlay(Image(nsImage: shot.image).resizable().scaledToFill())
                        .clipShape(slot)
                        .overlay(i == current ? slot.strokeBorder(Palette.accent, lineWidth: 1)
                                              : slot.strokeBorder(Palette.thumbBorder, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
                        .contentShape(slot)
                }
                .buttonStyle(.plain)
                .help("kiri-\(i + 1).png")
            }
        }
        .fixedSize()
    }

    // MARK: All images

    /// Every capture in aspect-aware rows that fit without scrolling. A click opens it in Single View.
    private var all: some View {
        GeometryReader { geo in
            let layout = KiriCore.GridLayout.arrange(model.shots.map(\.image.size), in: geo.size, padding: 0)
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(model.shots.indices, layout.tiles)), id: \.0) { i, t in
                    tile(i, t)
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height, alignment: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func tile(_ index: Int, _ t: KiriCore.GridLayout.Tile) -> some View {
        let shot = model.shots[index]
        let hovered = hoveredTileID == shot.id
        let shape = RoundedRectangle(cornerRadius: min(10, t.imageSize.height / 2, t.imageSize.width / 2),
                                     style: .continuous)
        let count = shot.comments.count
        return Button {
            state.select(shot.id)
            state.mode = .single
        } label: {
            Image(nsImage: shot.image)
                .resizable()
                .frame(width: t.imageSize.width, height: t.imageSize.height)
                .overlay(alignment: .bottomLeading) {
                    if hovered && !t.compact { badge("kiri-\(index + 1).png").padding(10) }
                }
                .overlay(alignment: .topTrailing) {
                    if count > 0 && !t.compact { badge("\(count) comment\(count == 1 ? "" : "s")").padding(10) }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(hovered ? Palette.muted : Palette.line, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredTileID = shot.id } else if hoveredTileID == shot.id { hoveredTileID = nil }
        }
        .frame(width: t.frame.width, height: t.frame.height, alignment: .top)
        .position(x: t.frame.midX, y: t.frame.midY)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.6)))
    }

    // MARK: Comments

    /// Pins a new comment where the preview was clicked and opens its editor.
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

    /// Removes empty comments once nothing is editing them: not the open editor, not a sidebar row
    /// with the text cursor.
    private func pruneComments() {
        var keep = Set<UUID>()
        if let id = state.commentID { keep.insert(id) }
        if case .sidebar(let id)? = focusedComment { keep.insert(id) }
        model.removeEmptyComments(keeping: keep)
    }

    private func deleteComment(_ id: UUID) {
        if state.commentID == id { state.commentID = nil }
        withAnimation(.easeOut(duration: 0.15)) { model.removeComment(id) }
    }

    /// The open comment's text field, floating to the right of its pin (or to the left when there's no
    /// room before the sidebar). Return or Esc closes it; an empty comment is then removed.
    @ViewBuilder
    private func commentEditor(_ anchors: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let id = state.commentID, let anchor = anchors[id], model.comment(id) != nil {
                let pin = proxy[anchor]
                let gap: CGFloat = 8
                let limit = proxy.size.width - Self.margin - Self.sidebarWidth - 1
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

    // MARK: Sidebar

    /// One note card per capture, in shelf order, above Copy to Agent. The cards scroll when they don't
    /// fit, keeping the selected one in view.
    private var sidebar: some View {
        let numbers = model.commentNumbers
        let current = currentIndex
        let cards = VStack(spacing: 12) {
            ForEach(Array(model.shots.enumerated()), id: \.element.id) { i, shot in
                NoteCard(name: "kiri-\(i + 1).png",
                         id: shot.id,
                         text: Binding(get: { model.shots.first { $0.id == shot.id }?.note ?? "" },
                                       set: { model.setNote(shot.id, $0) }),
                         dictation: dictation,
                         isActive: i == current,
                         focus: $focusedNote,
                         comments: shot.comments.map { (numbers[$0.id] ?? 0, $0.id) },
                         openComment: state.commentID,
                         commentText: commentText,
                         commentFocus: $focusedComment,
                         onSelect: { state.select(shot.id) },
                         onMic: { toggleListening(shot.id) },
                         onDeleteComment: deleteComment)
                    .id(shot.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        let result = result(.agent)
        return VStack(spacing: 16) {
            ViewThatFits(in: .vertical) {
                cards
                ScrollViewReader { reader in
                    ScrollView(.vertical) { cards }
                        .onChange(of: state.selectedID) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id) }
                        }
                }
            }
            Button {
                runShowingResult(.agent) { copyAll(asPaths: true) }
            } label: {
                HStack(spacing: 6) {
                    if result != nil { Image(systemName: "checkmark.circle.fill") }
                    Text(result ?? "Copy to Agent")
                }
                .font(.bricolage(14, weight: 500))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0x5B / 255, green: 0x21 / 255, blue: 0xB6 / 255)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy the paths of every capture as text, with their notes, for pasting into a terminal agent.")
        }
        .contentShape(Rectangle())
        .onTapGesture {}  // clicks in the sidebar don't reach the background
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Dictation appends to whatever the note already says.
    private func toggleListening(_ id: UUID) {
        if dictation.isBusy { return dictation.stop() }
        state.select(id)
        state.editing = true
        focusedNote = nil  // the box is read-only while dictating; focus returns when it finishes
        let base = model.shots.first { $0.id == id }?.note ?? ""
        Sounds.playDictate()
        dictation.start { [weak model] spoken in
            let sep = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
            model?.setNote(id, base + sep + spoken)
        }
    }
}

/// A header button: a white outlined capsule, grey on hover; `on` shows it pressed (Comment in comment mode).
private struct HeaderPill: View {
    let title: String
    var on = false
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.bricolage(12, weight: 500))
                .foregroundStyle(on ? Palette.bg : Palette.label)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(on ? Palette.text : hovered ? Palette.pillHover : Palette.pill)
                    .shadow(color: .black.opacity(0.03), radius: 1.5, y: 2))
                .overlay(Capsule().strokeBorder(Palette.pillBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// A borderless round button that gets a grey circle on hover and fades when disabled (the arrows).
private struct HoverCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(configuration: configuration)
    }

    private struct HoverCircle: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(Palette.text)
                .background(Circle().fill(hovered && enabled ? Palette.track : .clear))
                .opacity(enabled ? 1 : 0.25)
                .onHover { hovered = $0 }
        }
    }
}

/// One capture's card in the sidebar: its file name, the note box with a mic button, and its comments.
/// The selected capture's card has a dark border; clicking a card selects its capture. While this card
/// is dictating, its header shows a live mic waveform, the mic turns red (click it to stop), and the
/// box is read-only as the transcription writes into it.
private struct NoteCard: View {
    let name: String
    let id: UUID
    @Binding var text: String
    @ObservedObject var dictation: SpeechDictation
    /// The selected capture's card; dictation only runs on it.
    let isActive: Bool
    var focus: FocusState<UUID?>.Binding
    /// This capture's comments with their numbers, as editable rows under the note.
    let comments: [(number: Int, id: UUID)]
    /// The comment whose editor is open by its pin; its row gets a dark border.
    let openComment: UUID?
    var commentText: (UUID) -> Binding<String>
    var commentFocus: FocusState<CommentField?>.Binding
    var onSelect: () -> Void
    var onMic: () -> Void
    var onDeleteComment: (UUID) -> Void
    @State private var hoveredComment: UUID?

    private var listening: Bool { isActive && dictation.isListening }
    private var busy: Bool { isActive && dictation.isBusy }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.bricolage(12, weight: 500))
                    .foregroundStyle(isActive ? Palette.purple : Palette.subtle)
                    .lineLimit(1)
                if listening { LevelBars(levels: dictation.levels, color: Palette.red) }
                Spacer(minLength: 8)
                if busy && !listening {
                    Text("Finishing…").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            noteField
            if !comments.isEmpty {
                Text("Comments")
                    .font(.bricolage(10))
                    .foregroundStyle(Palette.subtle)
                ForEach(comments, id: \.id) { c in commentRow(c) }
            }
            if isActive, let error = dictation.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.bg)
            .shadow(color: Palette.shadow.opacity(isActive ? 0.1 : 0), radius: 5, y: 6)
            .shadow(color: Palette.shadow.opacity(isActive ? 0.1 : 0), radius: 3, y: 4))
        .overlay(shape.strokeBorder(isActive ? Palette.purple.opacity(0.5) : Palette.cardBorder, lineWidth: 1))
        .contentShape(shape)
        .onTapGesture(perform: onSelect)
    }

    private var noteField: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .center, spacing: 4) {
            TextField(listening ? "Start speaking…" : "Type or dictate thoughts here", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...8)
                .disabled(busy)  // the transcription is writing into it
                .focused(focus, equals: id)
                .padding(.vertical, 8)
            Button(action: onMic) {
                Image(systemName: listening ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(listening ? Palette.red : Palette.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(HoverCircleStyle())
            .disabled(dictation.isBusy && !listening)  // one dictation at a time; not while finishing
            .help(listening ? "Stop dictating" : "Dictate; it's added to the end of the note")
        }
        .padding(.leading, 9).padding(.trailing, 4)
        .background(shape.fill(Palette.bg))
        .overlay(shape.strokeBorder(Palette.line, lineWidth: 1))
    }

    private func commentRow(_ c: (number: Int, id: UUID)) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(c.number).").monospacedDigit()
            TextField("Comment", text: commentText(c.id), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .lineSpacing(3)
                .focused(commentFocus, equals: .sidebar(c.id))
            Button { onDeleteComment(c.id) } label: {
                Text("×").font(.system(size: 14)).frame(width: 22, height: 22).contentShape(Circle())
            }
            .buttonStyle(HoverCircleStyle())
            .opacity(hoveredComment == c.id ? 1 : 0)
            .help("Delete comment")
        }
        .font(.bricolage(10))
        .foregroundStyle(Palette.purple)
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
        .background(shape.fill(Palette.purple.opacity(0.1)))
        .overlay(shape.strokeBorder(openComment == c.id ? Palette.purple : .clear, lineWidth: 1))
        .onHover { inside in
            if inside { hoveredComment = c.id } else if hoveredComment == c.id { hoveredComment = nil }
        }
        .transition(.opacity)
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
            .font(.system(size: 12))
            .foregroundStyle(Palette.text)
            .lineLimit(1...8)
            .focused(focus, equals: .pin(id))
            .onSubmit(onDone)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(width: Self.width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.bg))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .contentShape(Rectangle())
            .onTapGesture {}  // clicks here don't reach the background (which would close it)
            .onAppear { DispatchQueue.main.async { focus.wrappedValue = .pin(id) } }
    }
}

/// The cursor over the preview in comment mode: the pin's outline with a +, pointing from its
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
