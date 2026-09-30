import AppKit
import SwiftUI
import KioCore

public enum CharacterMood: Sendable, Equatable {
    case idle, curious, thinking, working, success, failure
}

public struct AgentBlob: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kio.reduceCharacterMotion") private var reduceCharacterMotion = false
    @State private var blinking = false
    @State private var breathing = false
    @State private var workingBounce = false
    @State private var successHop = false
    @State private var eyeTracking = CGSize.zero
    @State private var idleGaze = CGSize.zero
    @State private var idleBob = false
    @State private var idleSway = false

    private let agent: AgentID
    private let mood: CharacterMood
    private let size: CGFloat
    private let gazeTarget: CGSize?

    public init(_ agent: AgentID, mood: CharacterMood = .idle, size: CGFloat = 36, gazeTarget: CGSize? = nil) {
        self.agent = agent
        self.mood = mood
        self.size = size
        self.gazeTarget = gazeTarget
    }

    public var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: size * 0.43, bottomLeadingRadius: size * 0.34,
                                   bottomTrailingRadius: size * 0.40, topTrailingRadius: size * 0.35)
                .fill(Color(hex: agent.colorHex))
                .frame(width: size, height: size * 0.83)
            Group {
                if mood == .success {
                    HStack(spacing: size * 0.075) {
                        SmileEye()
                            .stroke(eyeColor, style: StrokeStyle(lineWidth: max(1.4, size * 0.05), lineCap: .round))
                            .frame(width: max(5, size * 0.19), height: max(4, size * 0.12))
                        SmileEye()
                            .stroke(eyeColor, style: StrokeStyle(lineWidth: max(1.4, size * 0.05), lineCap: .round))
                            .frame(width: max(5, size * 0.19), height: max(4, size * 0.12))
                    }
                } else {
                    HStack(spacing: size * 0.12) {
                        Capsule().frame(width: max(3, size * 0.105), height: max(5, size * (blinking ? 0.045 : 0.23)))
                        Capsule().frame(width: max(3, size * 0.105), height: max(5, size * (blinking ? 0.045 : 0.23)))
                    }
                }
            }
            .foregroundStyle(eyeColor)
            .offset(x: pointerOffset.width + idleGaze.width,
                    y: size * 0.005 + eyeOffset + pointerOffset.height + idleGaze.height)
        }
        .offset(y: shapeOffset + idleBobOffset)
        .rotationEffect(idleRotation)
        .scaleEffect(x: shouldReduceMotion ? 1 : (breathing ? 1.018 : 0.99),
                     y: shouldReduceMotion ? 1 : (mood == .failure ? 0.985 : breathing ? 0.99 : 1.015))
        .frame(width: size, height: size)
        .animation(shouldReduceMotion ? nil : .easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathing)
        .animation(shouldReduceMotion ? nil : .easeOut(duration: 0.15), value: eyeTracking)
        .animation(shouldReduceMotion ? nil : .easeOut(duration: 0.15), value: gazeTarget)
        .animation(shouldReduceMotion ? nil : .easeInOut(duration: 0.48), value: idleGaze)
        .animation(shouldReduceMotion ? nil : .easeInOut(duration: 0.72), value: idleBob)
        .animation(shouldReduceMotion ? nil : .easeInOut(duration: 0.82), value: idleSway)
        .animation(shouldReduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.68), value: mood)
        .overlay {
            if gazeTarget == nil {
                AgentPointerTracker { location, bounds in
                    guard !shouldReduceMotion, let location else { eyeTracking = .zero; return }
                    let horizontal = min(1, max(-1, (location.x - bounds.width / 2) / max(1, bounds.width / 2)))
                    let vertical = min(1, max(-1, (bounds.height / 2 - location.y) / max(1, bounds.height / 2)))
                    eyeTracking = CGSize(width: horizontal * size * 0.035, height: vertical * size * 0.025)
                }
                .allowsHitTesting(false)
            }
        }
        .task(id: shouldReduceMotion) {
            guard !shouldReduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.7...6.1)))
                withAnimation(.easeInOut(duration: 0.11)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(130))
                withAnimation(.easeOut(duration: 0.14)) { blinking = false }
            }
        }
        .task(id: mood) {
            switch mood {
            case .idle, .curious:
                guard !shouldReduceMotion else { return }
                while !Task.isCancelled && (mood == .idle || mood == .curious) {
                    try? await Task.sleep(for: .seconds(Double.random(in: 1.4...3.2)))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.5)) {
                        idleGaze = CGSize(width: CGFloat.random(in: -0.045...0.045) * size,
                                          height: CGFloat.random(in: -0.025...0.025) * size)
                        idleBob.toggle()
                        idleSway.toggle()
                    }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 650...1100)))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.5)) {
                        idleGaze = .zero
                        idleBob = false
                        idleSway = false
                    }
                }
            case .working:
                idleGaze = .zero
                idleBob = false
                idleSway = false
                while !Task.isCancelled && mood == .working {
                    withAnimation(.easeInOut(duration: 0.34)) { workingBounce.toggle() }
                    try? await Task.sleep(for: .milliseconds(340))
                }
                workingBounce = false
            case .success where !shouldReduceMotion:
                idleGaze = .zero
                idleBob = false
                idleSway = false
                withAnimation(.spring(response: 0.24, dampingFraction: 0.56)) { successHop = true }
                try? await Task.sleep(for: .milliseconds(190))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { successHop = false }
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { successHop = true }
                try? await Task.sleep(for: .milliseconds(170))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { successHop = false }
            default:
                workingBounce = false
                successHop = false
                idleGaze = .zero
                idleBob = false
                idleSway = false
            }
        }
        .onAppear {
            guard !shouldReduceMotion else { return }
            breathing = true
        }
        .onChange(of: shouldReduceMotion) { _, reduced in
            if reduced { eyeTracking = .zero; breathing = false }
            else { breathing = true }
        }
        .accessibilityLabel("\(agent.name) character")
    }

    private var eyeOffset: CGFloat {
        switch mood {
        case .thinking: -size * 0.06
        case .failure: size * 0.025
        default: 0
        }
    }

    private var pointerOffset: CGSize {
        guard let gazeTarget, !shouldReduceMotion else { return eyeTracking }
        let horizontal = min(1, max(-1, gazeTarget.width))
        let vertical = min(1, max(-1, gazeTarget.height))
        return CGSize(width: horizontal * size * 0.035, height: vertical * size * 0.025)
    }

    private var eyeColor: Color { .black }

    private var idleBobOffset: CGFloat {
        guard !shouldReduceMotion, (mood == .idle || mood == .curious), idleBob else { return 0 }
        return -size * 0.035
    }

    private var idleRotation: Angle {
        guard !shouldReduceMotion else { return .zero }
        if mood == .curious { return .degrees(3) }
        if mood == .idle, idleSway { return .degrees(2.2) }
        return .zero
    }

    private var shapeOffset: CGFloat {
        if mood == .success && successHop && !shouldReduceMotion { return -size * 0.18 }
        if mood == .working && workingBounce && !shouldReduceMotion { return -size * 0.07 }
        if mood == .curious { return -size * 0.015 }
        if mood == .failure { return size * 0.055 }
        return 0
    }

    private var shouldReduceMotion: Bool { reduceMotion || reduceCharacterMotion }
}

private struct SmileEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }
}

private struct AgentPointerTracker: NSViewRepresentable {
    let onMove: (CGPoint?, CGSize) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onMove = onMove
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint?, CGSize) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil), bounds.size)
        }

        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseExited(with event: NSEvent) { onMove?(nil, bounds.size) }
    }
}

public struct AgentAvatar: View {
    private let agent: AgentID
    private let size: CGFloat

    public init(_ agent: AgentID, size: CGFloat = 26) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        AgentBlob(agent, size: size)
    }
}

public extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}
