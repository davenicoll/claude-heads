import SwiftUI

struct HeadView: View {
    let head: HeadInstance

    @State private var currentFaceText: String = HeadFace.awake.rawValue
    @State private var timer: Timer?
    @State private var sequencer = FaceSequencer()

    private var diameter: CGFloat {
        AppSettings.shared.headSize.diameter
    }

    private var emojiSize: CGFloat {
        diameter * 0.52
    }

    private var totalSize: CGFloat {
        diameter + emojiSize
    }

    private var faceColor: Color {
        .black
    }

    private var faceFontSize: CGFloat {
        diameter * 0.36
    }

    var body: some View {
        VStack(spacing: 2) {
            circleBackground
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 3)
                .overlay {
                    Text(currentFaceText)
                        .font(.system(size: faceFontSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(faceColor)
                        .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                        .offset(y: -diameter * 0.10)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    if AppSettings.shared.showStatusIndicator {
                        stateIndicator
                            .frame(width: 12, height: 12)
                            .offset(x: 2, y: -2)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if head.isWaving {
                        WaveEmoji(fontSize: emojiSize)
                            .offset(x: -emojiSize * 0.3, y: -emojiSize * 0.4)
                    }
                }
                .padding(.top, emojiSize * 0.5)
                .frame(width: totalSize)

            Text(head.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: diameter + 10)
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChange(of: head.state) { _, newState in
            sequencer.setState(newState)
            tick()
        }
        .onReceive(NotificationCenter.default.publisher(for: .headTapped)) { notification in
            if let tappedID = notification.object as? UUID, tappedID == head.id {
                sequencer.wake()
                tick()
            }
        }
    }

    private func startTimer() {
        sequencer.setState(head.state)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            tick()
        }
    }

    private func tick() {
        currentFaceText = sequencer.next().rawValue
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
        case .idle: .green
        case .running: .blue
        case .finished: .orange
        case .errored: .red
        }
    }
}

// MARK: - Wave Emoji Animation

private struct WaveEmoji: View {
    let fontSize: CGFloat
    @State private var angle: Double = 0

    var body: some View {
        Text("\u{1F44B}")
            .font(.system(size: fontSize))
            .rotationEffect(.degrees(angle), anchor: .bottomTrailing)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.3)
                        .repeatCount(6, autoreverses: true)
                ) {
                    angle = 30
                }
            }
    }
}
