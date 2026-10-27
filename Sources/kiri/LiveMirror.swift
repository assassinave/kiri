import AppKit

/// Keeps `$TMPDIR/kiri/live/` in step with the shelf: `kiri-N.png` in shelf order, plus `kiri-notes.md`
/// while any capture has a note. An agent can read the current captures without a Copy press.
/// Cleared at launch, so it never shows captures from an earlier run.
final class LiveMirror {
    static let folderName = "live"

    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kiri", isDirectory: true)
        .appendingPathComponent(LiveMirror.folderName, isDirectory: true)
    /// File work runs off the main thread, in order.
    private let queue = DispatchQueue(label: "dev.kiri.live-mirror")
    /// The shot each `kiri-N.png` on disk holds, in file order. Touched only on `queue`.
    private var written: [UUID] = []

    init() {
        let dir = dir
        queue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func sync(_ shots: [Shot]) {
        let items = shots.map { (id: $0.id, image: $0.cgImage, note: $0.context) }
        queue.async { [self] in write(items) }
    }

    private func write(_ items: [(id: UUID, image: CGImage, note: String)]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ids = items.map(\.id)
        if ids != written {
            // Captures that stay are renamed rather than re-encoded: move them aside first so
            // shifting numbers can't overwrite each other, then into their new places.
            let kept = Set(ids)
            for (i, id) in written.enumerated() {
                let file = png(i)
                if kept.contains(id) { try? fm.moveItem(at: file, to: staged(id)) }
                else { try? fm.removeItem(at: file) }
            }
            var now: [UUID] = []
            for (i, item) in items.enumerated() {
                let file = png(i)
                if (try? fm.moveItem(at: staged(item.id), to: file)) == nil {
                    guard let data = NSBitmapImageRep(cgImage: item.image).representation(using: .png, properties: [:]),
                          (try? data.write(to: file)) != nil
                    else { break }
                }
                now.append(item.id)
            }
            written = now
        }

        let notes = items.map { $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }
        let notesFile = dir.appendingPathComponent(Clipboard.notesFileName)
        if notes.contains(where: { !$0.isEmpty }) {
            let md = Clipboard.notesMarkdown(names: items.indices.map { png($0).lastPathComponent }, notes: notes)
            try? md.write(to: notesFile, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(at: notesFile)
        }
    }

    private func png(_ index: Int) -> URL { dir.appendingPathComponent("kiri-\(index + 1).png") }
    private func staged(_ id: UUID) -> URL { dir.appendingPathComponent(".\(id.uuidString).png") }
}
