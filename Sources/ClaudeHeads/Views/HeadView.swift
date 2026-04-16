import SwiftUI

struct HeadView: View {
    let head: HeadInstance
    var onTap: () -> Void

    private var diameter: CGFloat {
        AppSettings.shared.headSize.diameter
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Circle background: avatar or path-derived gradient
                circleBackground
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)

                // State indicator dot
                stateIndicator
                    .frame(width: 12, height: 12)
                    .offset(x: diameter / 2 - 8, y: -(diameter / 2 - 8))

                // Wave animation overlay
                if head.isWaving {
                    WaveEmoji()
                        .offset(x: diameter / 2 - 4, y: -(diameter / 2 - 4))
                }
            }

            // Folder name label
            Text(head.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: diameter + 10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }

    // MARK: - Circle Background

    @ViewBuilder
    private var circleBackground: some View {
        if let avatarData = head.avatarImageData,
           let nsImage = NSImage(data: avatarData) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            PathColorGenerator.gradient(for: head.folderPath)
        }
    }

    // MARK: - State Indicator

    @ViewBuilder
    private var stateIndicator: some View {
        Circle()
            .fill(stateColor)
            .overlay(
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
            )
    }

    private var stateColor: Color {
        switch head.state {
        case .running: .green
        case .idle: .orange
        case .finished: .blue
        case .errored: .red
        }
    }
}

// MARK: - Wave Emoji Animation

private struct WaveEmoji: View {
    @State private var angle: Double = 0

    var body: some View {
        Text("\u{1F44B}")
            .font(.system(size: 20))
            .rotationEffect(.degrees(angle), anchor: .bottomTrailing)
            .onAppear {
                withAnimation(
                    .interpolatingSpring(stiffness: 200, damping: 5)
                        .repeatCount(5, autoreverses: true)
                ) {
                    angle = 30
                }
            }
    }
}
