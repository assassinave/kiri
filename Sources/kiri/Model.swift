import AppKit
import Combine
import KiriCore

struct Shot: Identifiable {
    let id = UUID()
    let cgImage: CGImage
    let image: NSImage          // sized in points
    let date = Date()
    /// Context dictated or typed in the collection's sidebar; copied along with the image.
    var note = ""
    /// Pinned comments from the collection's comment mode, in the order they were added.
    var comments: [Comment] = []

    init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        self.image = NSImage(cgImage: cgImage,
                             size: NSSize(width: CGFloat(cgImage.width) / scale,
                                          height: CGFloat(cgImage.height) / scale))
    }

    /// The note plus each non-empty comment (numbered like its pin, with the pixel it points at),
    /// trimmed; what gets copied and exported alongside the image.
    var context: String {
        let comments = comments.enumerated().filter { !$1.isEmpty }.map { i, c in
            let x = Int(c.point.x * CGFloat(cgImage.width)), y = Int(c.point.y * CGFloat(cgImage.height))
            return "Comment \(i + 1) at (\(x), \(y)) px: \(c.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return ([note.trimmingCharacters(in: .whitespacesAndNewlines)] + comments)
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A comment pinned to a point on a capture in the collection's comment mode (C).
struct Comment: Identifiable {
    let id = UUID()
    /// Where the pin points, as a fraction of the image's width and height from its top-left.
    let point: CGPoint
    var text = ""

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
final class AppModel: ObservableObject {
    /// Oldest shots are dropped beyond this many (memory guard; not user-specified).
    static let maxShots = 20

    @Published var shots: [Shot] = []
    @Published var style: ShelfStyle
    @Published var isEnabled: Bool
    @Published var hotkey: HotkeyCombo
    @Published var hotkeyError: String?
    @Published var showAllHotkey: HotkeyCombo
    @Published var showAllHotkeyError: String?

    private let defaults = UserDefaults.standard
    private enum Key {
        static let style = "shelfStyle"
        static let enabled = "isEnabled"
        static let hotkey = "hotkey"
        static let showAllHotkey = "showAllHotkey"
    }

    init() {
        if let data = defaults.data(forKey: Key.style),
           let s = try? JSONDecoder().decode(ShelfStyle.self, from: data) {
            style = s
        } else {
            style = .default
        }
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Key.hotkey),
           let h = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            hotkey = h
        } else {
            hotkey = .default
        }
        if let data = defaults.data(forKey: Key.showAllHotkey),
           let h = try? JSONDecoder().decode(HotkeyCombo.self, from: data) {
            showAllHotkey = h
        } else {
            showAllHotkey = .defaultShowAll
        }
    }

    func persist() {
        defaults.set(try? JSONEncoder().encode(style), forKey: Key.style)
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(try? JSONEncoder().encode(hotkey), forKey: Key.hotkey)
        defaults.set(try? JSONEncoder().encode(showAllHotkey), forKey: Key.showAllHotkey)
    }

    func add(_ shot: Shot) {
        shots.append(shot)
        if shots.count > Self.maxShots { shots.removeFirst(shots.count - Self.maxShots) }
    }

    func remove(_ id: UUID) { shots.removeAll { $0.id == id } }
    func setNote(_ id: UUID, _ note: String) {
        guard let i = shots.firstIndex(where: { $0.id == id }), shots[i].note != note else { return }
        shots[i].note = note
    }
    func clear() { shots.removeAll() }

    /// Adds an empty comment pinned at `point` (0–1 of the image) and returns its id.
    func addComment(to shotID: UUID, at point: CGPoint) -> UUID? {
        guard let i = shots.firstIndex(where: { $0.id == shotID }) else { return nil }
        let comment = Comment(point: point)
        shots[i].comments.append(comment)
        return comment.id
    }

    func comment(_ id: UUID) -> Comment? {
        for shot in shots { if let c = shot.comments.first(where: { $0.id == id }) { return c } }
        return nil
    }

    func setComment(_ id: UUID, _ text: String) {
        for i in shots.indices {
            guard let j = shots[i].comments.firstIndex(where: { $0.id == id }) else { continue }
            if shots[i].comments[j].text != text { shots[i].comments[j].text = text }
            return
        }
    }

    func removeComment(_ id: UUID) {
        for i in shots.indices where shots[i].comments.contains(where: { $0.id == id }) {
            shots[i].comments.removeAll { $0.id == id }
        }
    }

    /// Drops comments left empty, except those still being edited.
    func removeEmptyComments(keeping keep: Set<UUID>) {
        for i in shots.indices where shots[i].comments.contains(where: { $0.isEmpty && !keep.contains($0.id) }) {
            shots[i].comments.removeAll { $0.isEmpty && !keep.contains($0.id) }
        }
    }

    /// Each comment's number: 1, 2, 3… in creation order within its capture, closing gaps left by
    /// removed comments.
    var commentNumbers: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: shots.flatMap { $0.comments.enumerated().map { ($1.id, $0 + 1) } })
    }
}
