import AppKit
import AVFoundation
import Speech
import SwiftUI

/// Every permission kiri uses, in one place, with live status.
enum Permission: CaseIterable, Identifiable {
    case screenRecording, accessibility, microphone, speechRecognition
    var id: Self { self }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: return "Required to capture anything."
        case .accessibility: return "Click to capture a UI element; scroll under the selector."
        case .microphone: return "Dictating notes in the show-all grid."
        case .speechRecognition: return "Turning dictated notes into text."
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .microphone: return "Privacy_Microphone"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return ElementHitTester.isTrusted
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// Microphone and Speech Recognition can tell "never asked" from "denied"; the other two can't.
    var wasNeverAsked: Bool {
        switch self {
        case .screenRecording, .accessibility: return !isGranted
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        case .speechRecognition: return SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }
    }

    /// Asks in-app when macOS allows it (Microphone, Speech Recognition the first time). Otherwise it
    /// registers kiri with the system list and opens that pane of System Settings, where the switch is.
    func request() {
        switch self {
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            openSettings()
        case .accessibility:
            ElementHitTester.requestTrust()
            openSettings()
        case .microphone:
            if wasNeverAsked { AVCaptureDevice.requestAccess(for: .audio) { _ in } } else { openSettings() }
        case .speechRecognition:
            if wasNeverAsked { SFSpeechRecognizer.requestAuthorization { _ in } } else { openSettings() }
        }
    }

    private func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionsView: View {
    /// Re-read every second while the window is open, since grants happen in System Settings.
    @State private var granted: [Permission: Bool] = Self.currentStatus()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static func currentStatus() -> [Permission: Bool] {
        Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("kiri needs these permissions. Allow each one; the status updates on its own.")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Permission.allCases) { row($0) }
            Divider()
            HStack(alignment: .top) {
                Text("macOS may only apply Screen Recording after kiri restarts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Relaunch kiri", action: Self.relaunch)
            }
        }
        .onReceive(timer) { _ in granted = Self.currentStatus() }
    }

    private func row(_ p: Permission) -> some View {
        let ok = granted[p] ?? false
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.headline)
                Text(p.purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if ok {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…") { p.request() }
            }
        }
    }

    /// Starts a new copy of the bundle once this one has quit.
    private static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
