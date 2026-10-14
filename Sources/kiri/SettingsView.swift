import SwiftUI
import ServiceManagement
import KiriCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Which shortcut the recorder is capturing, if any.
    @State private var recording: ReferenceWritableKeyPath<AppModel, HotkeyCombo>?
    @State private var monitor: Any?
    @State private var loginError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Shelf") {
                Picker("Orientation", selection: $model.style.orientation) {
                    Text("Horizontal").tag(ShelfOrientation.horizontal)
                    Text("Vertical").tag(ShelfOrientation.vertical)
                }
                .pickerStyle(.segmented)

                if model.style.orientation == .vertical {
                    Picker("Edge", selection: $model.style.edge) {
                        Text("Left").tag(ShelfEdge.left)
                        Text("Right").tag(ShelfEdge.right)
                    }
                    .pickerStyle(.segmented)
                    Text("Vertical cards sit \(Int(ShelfLayout.verticalHiddenFraction * 100))% past the screen edge.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Edge", value: "Top")
                }

                slider("Card width", value: $model.style.cardWidth, range: 80...280, step: 1, format: "%.0f px")
                slider("Overlap", value: overlapPercent, range: 0...80, step: 1, format: "%.0f%%")
                slider("Rotation ±", value: $model.style.rotation, range: 0...20, step: 0.1, format: "%.1f°")
                slider("Corner radius", value: $model.style.cornerRadius, range: 0...28, step: 1, format: "%.0f px")
            }

            Section("Shortcuts") {
                shortcutRow("Capture", \.hotkey, error: model.hotkeyError)
                shortcutRow("Show all captures", \.showAllHotkey, error: model.showAllHotkeyError)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { stopRecording() }
    }

    private var overlapPercent: Binding<CGFloat> {
        Binding(get: { model.style.overlap * 100 }, set: { model.style.overlap = $0 / 100 })
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>,
                        step: CGFloat, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, Double(value.wrappedValue))).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    @ViewBuilder
    private func shortcutRow(_ title: String, _ keyPath: ReferenceWritableKeyPath<AppModel, HotkeyCombo>,
                             error: String?) -> some View {
        LabeledContent(title) {
            Button(recording == keyPath ? "Press shortcut… (Esc cancels)" : model[keyPath: keyPath].displayString) {
                recording == keyPath ? stopRecording() : startRecording(keyPath)
            }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func startRecording(_ keyPath: ReferenceWritableKeyPath<AppModel, HotkeyCombo>) {
        stopRecording()
        recording = keyPath
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            let mods = HotkeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }   // require a modifier
            model[keyPath: keyPath] = HotkeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Launch at login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
