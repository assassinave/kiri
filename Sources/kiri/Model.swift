import AppKit
import Combine
import KiriCore

struct Shot: Identifiable {
    let id = UUID()
    let cgImage: CGImage
    let image: NSImage          // sized in points
    let date = Date()
    /// Context dictated or typed in the show-all grid; copied along with the image.
    var note = ""

    init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        self.image = NSImage(cgImage: cgImage,
                             size: NSSize(width: CGFloat(cgImage.width) / scale,
                                          height: CGFloat(cgImage.height) / scale))
    }
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
}
