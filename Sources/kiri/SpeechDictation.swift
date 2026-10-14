import AVFoundation
import Speech

/// Live speech-to-text from the default microphone (Speech framework), used for capture notes.
/// Needs Microphone and Speech Recognition permission; the usage strings are in Info.plist, so this
/// only works when running the app bundle.
@MainActor
final class SpeechDictation: ObservableObject {
    /// The microphone is on.
    @Published private(set) var isListening = false
    /// Listening, or waiting for the final transcription after the mic was turned off.
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    /// Recent microphone levels (0…1, oldest first), for a live waveform while listening.
    @Published private(set) var levels = [Float](repeating: 0, count: SpeechDictation.levelCount)
    static let levelCount = 24

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped per session so late callbacks from an earlier session are ignored.
    private var session = 0

    /// Starts listening. `onText` receives the whole transcription so far each time it changes,
    /// including the final one that arrives shortly after `stop()`.
    func start(onText: @escaping (String) -> Void) {
        guard !isBusy else { return }
        error = nil
        isBusy = true
        session += 1
        let session = session
        Task {
            guard await Self.speechAuthorized() else {
                return fail(session, "Speech Recognition access is off. Allow kiri in System Settings › Privacy & Security › Speech Recognition.")
            }
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                return fail(session, "Microphone access is off. Allow kiri in System Settings › Privacy & Security › Microphone.")
            }
            guard session == self.session, isBusy else { return }  // stopped while asking
            begin(session, onText: onText)
        }
    }

    /// Turns the microphone off; the final transcription still arrives through `onText`.
    func stop() {
        guard isBusy else { return }
        if isListening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            isListening = false
        } else {
            finish(session)  // still asking for permission
        }
    }

    private func begin(_ session: Int, onText: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            return fail(session, "Speech recognition isn't available for this language right now.")
        }
        // Audio never leaves the Mac: without on-device support, fail rather than fall back to Apple's servers.
        guard recognizer.supportsOnDeviceRecognition else {
            return fail(session, "On-device dictation isn't available for \(recognizer.locale.identifier). You can still type the note.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let input = engine.inputNode
        Self.installTap(on: input, feeding: request, level: Self.levelHandler { [weak self] level in
            guard let self, session == self.session, self.isListening else { return }
            self.levels = Array(self.levels.dropFirst()) + [level]
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return fail(session, "Couldn't start the microphone.")
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler { [weak self] text, done in
            guard let self, session == self.session else { return }
            if let text { onText(text) }
            if done { self.finish(session) }
        })
        isListening = true
    }

    private func fail(_ session: Int, _ message: String) {
        guard session == self.session else { return }
        finish(session)
        error = message
    }

    private func finish(_ session: Int) {
        guard session == self.session else { return }
        if isListening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        isBusy = false
        levels = [Float](repeating: 0, count: Self.levelCount)
    }

    // Callbacks below run on audio/recognition threads, so they're built outside the main actor.

    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    nonisolated private static func installTap(on input: AVAudioInputNode,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping (Float) -> Void) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
            level(Self.level(of: buffer))
        }
    }

    /// RMS of the first channel, mapped from -50…-10 dBFS to 0…1.
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return min(1, max(0, (db + 50) / 40))
    }

    nonisolated private static func levelHandler(_ handle: @escaping @MainActor (Float) -> Void) -> (Float) -> Void {
        { level in DispatchQueue.main.async { MainActor.assumeIsolated { handle(level) } } }
    }

    nonisolated private static func resultHandler(
        _ handle: @escaping @MainActor (String?, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            DispatchQueue.main.async { MainActor.assumeIsolated { handle(text, done) } }
        }
    }
}
