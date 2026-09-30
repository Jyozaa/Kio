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

    private let agent: AgentID
    private let mood: CharacterMood
    private let size: CGFloat

    public init(_ agent: AgentID, mood: CharacterMood = .idle, size: CGFloat = 36) {
        self.agent = agent
        self.mood = mood
        self.size = size
    }

    public var body: some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: size * 0.43, bottomLeadingRadius: size * 0.34,
                                   bottomTrailingRadius: size * 0.40, topTrailingRadius: size * 0.35)
                .fill(Color(hex: agent.colorHex))
                .frame(width: size, height: size * 0.83)
                .scaleEffect(x: shouldReduceMotion ? 1 : (breathing ? 1.018 : 0.99), y: shouldReduceMotion ? 1 : (breathing ? 0.99 : 1.015))
                .offset(y: mood == .failure ? 2 : 0)
            HStack(spacing: size * 0.12) {
                Capsule().frame(width: max(3, size * 0.105), height: max(5, size * (blinking ? 0.045 : 0.23)))
                Capsule().frame(width: max(3, size * 0.105), height: max(5, size * (blinking ? 0.045 : 0.23)))
            }
            .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.18))
            .offset(y: size * 0.005 + eyeOffset)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.64), value: mood)
        .task {
            guard !shouldReduceMotion else { return }
            breathing = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.7...6.1)))
                withAnimation(.easeInOut(duration: 0.11)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(130))
                withAnimation(.easeOut(duration: 0.14)) { blinking = false }
            }
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

    private var shouldReduceMotion: Bool { reduceMotion || reduceCharacterMotion }
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
