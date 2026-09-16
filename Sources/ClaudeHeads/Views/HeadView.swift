import SwiftUI

struct HeadView: View {
    let head: HeadInstance

    @State private var currentFaceText: String = HeadFace.awake.rawValue
    @State private var timer: Timer?
    @State private var sequencer = FaceSequencer()

    private var geometry: HeadGeometry {
        HeadGeometry.current
    }

    private var diameter: CGFloat { geometry.diameter }
    private var emojiSize: CGFloat { geometry.emojiSize }
    private var totalSize: CGFloat { geometry.totalWidth }

    private var faceColor: Color {
        .black
    }

    private var faceFontSize: CGFloat {
        diameter * 0.36
    }

    var body: some View {
        VStack(spacing: HeadGeometry.labelSpacing) {
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
                            .offset(x: emojiSize * HeadGeometry.emojiOffsetX, y: emojiSize * HeadGeometry.emojiOffsetY)
                    }
                }
                .overlay {
                    // Subagents orbit the circle; the overlay is centred on it and is
                    // allowed to draw outside its bounds (the hosting panel is enlarged
                    // while subagent children are shown). With "Show children for
                    // subagents" off the view gets no children, so it renders nothing and
                    // its TimelineView stays paused; the model keeps tracking children so
                    // they reappear as soon as it is turned back on. The removal is not
                    // animated then, because the panel has already shrunk and would clip it.
                    let showChildren = AppSettings.shared.showSubagentChildren
                    SubagentOrbitView(
                        children: showChildren ? head.children : [],
                        layout: OrbitLayout.current,
                        animatesChanges: showChildren
                    )
                }
                .padding(.top, emojiSize * HeadGeometry.emojiTopPadding)
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

// MARK: - Subagent Orbit

/// Draws each of a head's subagents as a small head on a slowly rotating ring around
/// the parent circle. The ring only animates while there are children; with none it
/// renders nothing and schedules no frames.
struct SubagentOrbitView: View {
    let children: [SubagentInstance]
    let layout: OrbitLayout
    /// Whether children appearing/disappearing spring in and out. Off while the orbit is
    /// hidden by settings, so the hide is instant rather than clipped by the shrunk panel.
    var animatesChanges: Bool = true

    @State private var hoveredID: String?

    private var childIDs: [String] { children.map(\.id) }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: children.isEmpty)) { context in
            // Children sit at fixed phase-0 offsets and the whole ring is rotated once per
            // frame; each child counter-rotates so its face and caption stay upright. Only
            // transforms change per tick, so no child body (gradient, shadow, text) is
            // rebuilt or re-rasterised while the ring turns.
            //
            // OrbitLayout angles grow counter-clockwise in y-up space; SwiftUI's
            // rotationEffect is clockwise on screen, hence the negated ring angle.
            let phase = OrbitLayout.phase(at: context.date)
            ZStack {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    let o = layout.offset(index: index, count: children.count, phase: 0)
                    SubagentHeadView(child: child, diameter: layout.childDiameter, isHovered: hoveredID == child.id)
                        .rotationEffect(.radians(phase))
                        .offset(x: o.dx, y: -o.dy)
                        .onHover { inside in
                            if inside {
                                hoveredID = child.id
                            } else if hoveredID == child.id {
                                hoveredID = nil
                            }
                        }
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .rotationEffect(.radians(-phase))
        }
        .animation(animatesChanges ? .spring(duration: 0.35) : nil, value: childIDs)
        .allowsHitTesting(!children.isEmpty)
        .onChange(of: childIDs) { _, ids in
            if let hoveredID, !ids.contains(hoveredID) { self.hoveredID = nil }
        }
    }
}

/// A single orbiting subagent: a miniature head coloured by its agent type, with a
/// caption showing its label (task description, else type, else id) while hovered.
private struct SubagentHeadView: View {
    let child: SubagentInstance
    let diameter: CGFloat
    let isHovered: Bool

    var body: some View {
        PathColorGenerator.gradient(for: child.colorKey)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 2)
            .overlay {
                Text(HeadFace.intense.rawValue)
                    .font(.system(size: diameter * 0.36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .offset(y: -diameter * 0.10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if isHovered {
                    Text(child.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: Capsule())
                        .fixedSize()
                        .offset(y: -(diameter * 0.35 + 14))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .help(child.tooltip)
            .accessibilityLabel("Subagent \(child.label)")
    }
}
