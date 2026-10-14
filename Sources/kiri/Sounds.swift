import AppKit

/// Feedback sounds, from `Resources/Sounds` (copied into the app bundle by `build_app.sh`).
/// Files are named `default-<action>-normal.wav`. Outside the bundle (a bare `swift run`) they're silent.
@MainActor
enum Sounds {
    private static let capture = load("default-capture-normal")
    private static let copy = load("default-copy-normal")
    private static let delete = load("default-delete-normal")
    private static let dictate = load("default-dictate-normal")

    static func playCapture() { play(capture) }
    static func playCopy() { play(copy) }
    static func playDelete() { play(delete) }
    static func playDictate() { play(dictate) }

    private static func load(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    /// Restarts the sound if it's still playing, so quick repeats each make a sound.
    private static func play(_ sound: NSSound?) {
        sound?.stop()
        sound?.play()
    }
}
