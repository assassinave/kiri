import SwiftUI
import KiriCore

@MainActor
final class ShelfState: ObservableObject {
    @Published var shots: [Shot] = []
    @Published var geometry: ShelfGeometry?
    @Published var style: ShelfStyle = .default
}

struct ShelfRootView: View {
    @ObservedObject var state: ShelfState
    var onClose: (UUID) -> Void
    var onShowAll: () -> Void
    @State private var hoveredID: UUID?

    var body: some View {
        let size = ShelfLayout.cardSize(width: state.style.cardWidth)
        let edge = state.style.effectiveEdge
        ZStack(alignment: .topLeading) {
            if let geo = state.geometry {
                ForEach(Array(state.shots.enumerated()), id: \.element.id) { index, shot in
                    if index < geo.placements.count {
                        let p = geo.placements[index]
                        let hovered = hoveredID == shot.id
                        ShotCardView(shot: shot, size: size, cornerRadius: state.style.cornerRadius,
                                     hovered: hovered, edge: edge, onClose: { onClose(shot.id) })
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hoveredID = shot.id }
                                else if hoveredID == shot.id { hoveredID = nil }
                            }
                            .onTapGesture { ShotCardView.copyNotifier.send(shot.id) }
                            .rotationEffect(.degrees(p.rotation))
                            .position(x: p.origin.x + size.width / 2, y: p.origin.y + size.height / 2)
                            .zIndex(hovered ? 1000 : Double(index))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                Button(action: onShowAll) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2.fill")
                        Text("\(state.shots.count)").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: ShelfLayout.pillSize.width, height: ShelfLayout.pillSize.height)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .overlay(Capsule().strokeBorder(ShotCardView.borderColor.opacity(0.6), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .position(geo.pillCenter)
                .zIndex(Double(state.shots.count))
            }
        }
        .frame(width: state.geometry?.panelRect.width ?? 0,
               height: state.geometry?.panelRect.height ?? 0,
               alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.geometry)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.shots.map(\.id))
    }
}
