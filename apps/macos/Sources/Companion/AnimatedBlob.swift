import SwiftUI

enum KioBlobMood {
    case idle
    case listening
    case thinking
    case complete
    case attention

    var colors: [Color] {
        switch self {
        case .idle: [.cyan, Color(red: 0.35, green: 0.42, blue: 0.98)]
        case .listening: [Color(red: 0.20, green: 0.92, blue: 0.75), .cyan]
        case .thinking: [Color(red: 0.48, green: 0.42, blue: 0.98), .cyan]
        case .complete: [Color(red: 0.27, green: 0.83, blue: 0.55), .cyan]
        case .attention: [Color(red: 1.0, green: 0.69, blue: 0.27), .orange]
        }
    }

    var label: String {
        switch self {
        case .idle: "Kio ready"
        case .listening: "Kio listening"
        case .thinking: "Kio working"
        case .complete: "Kio complete"
        case .attention: "Kio needs attention"
        }
    }

    var speed: Double {
        switch self {
        case .idle: 0.62
        case .listening: 1.15
        case .thinking: 1.75
        case .complete: 0.9
        case .attention: 0.48
        }
    }

    var intensity: Double {
        switch self {
        case .idle: 0.14
        case .listening: 0.20
        case .thinking: 0.17
        case .complete: 0.11
        case .attention: 0.10
        }
    }
}

struct KioAnimatedBlob: View {
    let mood: KioBlobMood
    var audioLevel = 0.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = min(max(audioLevel, 0), 1)
            let intensity = mood == .listening ? mood.intensity + level * 0.12 : mood.intensity
            ZStack {
                BlobShape(phase: time * mood.speed, intensity: intensity)
                    .fill(
                        LinearGradient(
                            colors: mood.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(alignment: .topLeading) {
                        Ellipse()
                            .fill(.white.opacity(0.24))
                            .frame(width: 19, height: 5)
                            .rotationEffect(.degrees(-28))
                            .offset(x: 12, y: 11)
                    }
                    .overlay {
                        BlobMark(mood: mood, time: time, audioLevel: level)
                    }
                    .overlay {
                        BlobShape(phase: time * mood.speed, intensity: intensity)
                            .stroke(.white.opacity(0.22), lineWidth: 0.8)
                    }
                    .shadow(color: mood.colors[0].opacity(0.20), radius: 5, y: 2)
            }
            .frame(width: 46, height: 46)
            .accessibilityElement()
            .accessibilityLabel(mood.label)
        }
    }
}

private struct BlobMark: View {
    let mood: KioBlobMood
    let time: Double
    let audioLevel: Double

    @ViewBuilder
    var body: some View {
        switch mood {
        case .idle:
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))
        case .listening:
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<3) { index in
                    let wave = abs(sin(time * 5.2 + Double(index) * 1.1))
                    Capsule()
                        .fill(.white.opacity(0.96))
                        .frame(width: 2.4, height: 5 + 8 * max(wave * 0.65, audioLevel))
                }
            }
        case .thinking:
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(.white.opacity(0.45 + 0.5 * abs(sin(time * 4 + Double(index) * 1.2))))
                        .frame(width: 3.2, height: 3.2)
                }
            }
        case .complete:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        case .attention:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

private struct BlobShape: Shape {
    var phase: Double
    var intensity: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(phase, intensity) }
        set {
            phase = newValue.first
            intensity = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.44
        let points = (0..<64).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / 64
            let rhythm = sin(3 * angle + phase)
                + 0.48 * sin(2 * angle - phase * 0.73)
                + 0.28 * sin(5 * angle + phase * 0.51)
            let adjustedRadius = radius * (1 + intensity * rhythm / 1.76)
            return CGPoint(
                x: center.x + cos(angle) * adjustedRadius,
                y: center.y + sin(angle) * adjustedRadius
            )
        }
        guard let first = points.first, let last = points.last else { return Path() }

        var path = Path()
        path.move(to: midpoint(last, first))
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            path.addQuadCurve(to: midpoint(current, next), control: current)
        }
        path.closeSubpath()
        return path
    }

    private func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }
}
