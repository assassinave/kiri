import SwiftUI

/// Two steps: macOS permissions (`PermissionsView`), then turning on Chrome's accessibility mode so
/// element picking works in Chrome (see `ChromeAccessibility`).
struct OnboardingView: View {
    @State private var step = 1
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(step == 1 ? "Permissions" : "Element picking in Chrome").font(.title2.bold())
                Spacer()
                Text("\(step) of 2").foregroundStyle(.secondary)
            }
            if step == 1 { PermissionsView() } else { ChromeStepView() }
            Divider()
            HStack {
                if step == 2 { Button("Back") { step = 1 } }
                Spacer()
                if step == 1 {
                    Button("Next") { step = 2 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct ChromeStepView: View {
    @State private var state: ChromeAccessibility.State?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("To click a single element on a web page in Google Chrome, turn on Chrome's accessibility support. Safari doesn't need this. Other browsers built on Chrome (Edge, Brave, Arc) probably need the same setting, but kiri doesn't check them.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Click **Open Chrome Accessibility** below.")
                Text("2. Turn on **Native accessibility API support** and **Web accessibility**.")
            }
            Text("Chrome turns this off whenever it restarts or updates. The kiri menu shows when it's off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                statusLabel
                Spacer()
                Button("Open Chrome Accessibility", action: ChromeAccessibility.openSettingsPage)
                    .disabled(!ChromeAccessibility.isInstalled)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    @ViewBuilder private var statusLabel: some View {
        switch state {
        case .on:
            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .off:
            Label("Off", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .notRunning:
            Text(ChromeAccessibility.isInstalled ? "Chrome isn't running" : "Chrome isn't installed")
                .foregroundStyle(.secondary)
        case .noWindows:
            Text("Open a Chrome window to check").foregroundStyle(.secondary)
        case .unknown:
            Text("Allow Accessibility first (step 1)").foregroundStyle(.secondary)
        case nil:
            Text("Checking…").foregroundStyle(.secondary)
        }
    }

    /// The check walks Chrome's accessibility tree, so it runs off the main thread.
    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = ChromeAccessibility.state()
            DispatchQueue.main.async { state = s }
        }
    }
}
