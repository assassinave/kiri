import SwiftUI
import Combine
import KiriCore

struct ShotCardView: View {
    /// Tap on the card (handled by the parent so hover/hit area stays stable) funnels through here.
    static let copyNotifier = PassthroughSubject<UUID, Never>()

    /// #F7F7F7
    static let borderColor = Color(nsColor: NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1))

    let shot: Shot
    let size: CGSize
    let cornerRadius: CGFloat
    let hovered: Bool
    /// Shelf edge the card lifts away from on hover; nil (the collection's preview) means no lift.
    let edge: ShelfEdge?
    static let defaultHoverScale: CGFloat = 1.04
    /// How much the card grows on hover (the collection's preview doesn't).
    var hoverScale: CGFloat = defaultHoverScale
    /// False hides × (the collection's comment mode, where a click pins a comment instead).
    var showsClose = true
    let onClose: () -> Void

    static func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.black.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    @State private var copied = false
    @State private var copyToken = 0

    private var lift: CGSize {
        let d = ShelfLayout.hoverLift
        switch edge {
        case nil: return .zero
        case .top: return CGSize(width: 0, height: d)
        case .left: return CGSize(width: d, height: 0)
        case .right: return CGSize(width: -d, height: 0)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Image(nsImage: shot.image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()

            if hovered && !copied && showsClose {
                Self.closeButton(action: onClose)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity)
            }

            if copied {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: min(size.height * 0.4, 34)))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color(red: 0.19, green: 0.82, blue: 0.35))
                        Text("Copied")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(copied ? Color(red: 0.19, green: 0.82, blue: 0.35) : Self.borderColor,
                                    lineWidth: copied ? 2.5 : 2))
        .shadow(color: .black.opacity(hovered ? 0.45 : 0.35), radius: hovered ? 10 : 6, y: hovered ? 5 : 3)
        .scaleEffect(hovered ? hoverScale : 1)
        .offset(hovered ? lift : .zero)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: copied)
        .onReceive(Self.copyNotifier) { id in
            guard id == shot.id else { return }
            if Clipboard.copy(shot) { Sounds.playCopy() }
            copyToken += 1
            let token = copyToken
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if token == copyToken { copied = false }
            }
        }
    }
}
