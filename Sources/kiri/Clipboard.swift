import AppKit

enum Clipboard {
    @discardableResult
    static func copy(_ shot: Shot) -> Bool {
        let rep = NSBitmapImageRep(cgImage: shot.cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        // The note rides along as text; the pasting app picks the type it wants.
        let note = shot.note.trimmingCharacters(in: .whitespacesAndNewlines)
        pb.declareTypes(note.isEmpty ? [.png, .tiff] : [.png, .tiff, .string], owner: nil)
        let okPNG = pb.setData(png, forType: .png)
        let okTIFF = rep.tiffRepresentation.map { pb.setData($0, forType: .tiff) } ?? false
        if !note.isEmpty { pb.setString(note, forType: .string) }
        return okPNG || okTIFF
    }

    enum MultiFormat {
        /// One file reference per shot, like copying files in Finder (works for pasting into web/chat apps).
        case files
        /// The files' absolute paths as text, one per line (for terminal agents such as Claude Code).
        case paths
    }

    static let notesFileName = "kiri-notes.md"

    /// Writes every shot as a PNG to a new folder under the temporary directory, plus `kiri-notes.md`
    /// if any shot has a note, then copies them in the given format. Notes go along too: as the
    /// notes file (one more file reference) for `.files`, or as `Note:` lines under each path for `.paths`.
    @discardableResult
    static func copyAll(_ shots: [Shot], as format: MultiFormat) -> Bool {
        guard !shots.isEmpty, let dir = makeFolder(),
              // Both formats leave the notes in the folder, so an agent can read the export from disk.
              let (urls, notesURL) = export(shots, to: dir)
        else { return false }
        let notes = trimmedNotes(shots)
        let pb = NSPasteboard.general
        pb.clearContents()
        switch format {
        case .files:
            let files = urls + (notesURL.map { [$0] } ?? [])
            return pb.writeObjects(files.map { $0 as NSURL })
        case .paths:
            let text = zip(urls, notes).map { url, note in
                note.isEmpty ? url.path : "\(url.path)\nNote: \(note)"
            }.joined(separator: "\n")
            return pb.setString(text, forType: .string)
        }
    }

    /// The file names `export` writes for these shots, for checking what it would replace.
    static func exportNames(_ shots: [Shot]) -> [String] {
        shots.indices.map { "kiri-\($0 + 1).png" }
            + (trimmedNotes(shots).contains { !$0.isEmpty } ? [notesFileName] : [])
    }

    /// Writes every shot as `kiri-N.png` into `dir`, plus `kiri-notes.md` if any shot has a note.
    /// Existing files with those names are replaced.
    static func export(_ shots: [Shot], to dir: URL) -> (images: [URL], notes: URL?)? {
        var pngs: [Data] = []
        for shot in shots {
            guard let png = NSBitmapImageRep(cgImage: shot.cgImage).representation(using: .png, properties: [:])
            else { return nil }
            pngs.append(png)
        }
        guard let urls = write(pngs, to: dir) else { return nil }
        let notes = trimmedNotes(shots)
        guard notes.contains(where: { !$0.isEmpty }) else { return (urls, nil) }
        let md = notesMarkdown(names: urls.map(\.lastPathComponent), notes: notes)
        let url = dir.appendingPathComponent(notesFileName)
        guard (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return (urls, url)
    }

    private static func trimmedNotes(_ shots: [Shot]) -> [String] {
        shots.map { $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// One section per capture that has a note, titled with its PNG's file name.
    static func notesMarkdown(names: [String], notes: [String]) -> String {
        let sections = zip(names, notes).filter { !$0.1.isEmpty }.map { "## \($0)\n\n\($1)\n" }
        return "# kiri notes\n\n" + sections.joined(separator: "\n")
    }

    /// A fresh folder per copy, so earlier copies' files stay valid until the system clears the temp dir.
    private static func makeFolder() -> URL? {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted))
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiri", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }
        return dir
    }

    private static func write(_ pngs: [Data], to dir: URL) -> [URL]? {
        try? pngs.enumerated().map { i, png in
            let url = dir.appendingPathComponent("kiri-\(i + 1).png")
            try png.write(to: url)
            return url
        }
    }
}
