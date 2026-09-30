import AppKit

@MainActor
enum KioSoundEffects {
    private static let preferenceKey = "kioSoundEffectsEnabled"
    private static var sounds: [Event: NSSound] = [:]

    enum Event: Hashable {
        case listening
        case complete
        case attention

        var name: String {
            switch self {
            case .listening: "Tink"
            case .complete: "Pop"
            case .attention: "Purr"
            }
        }

        var volume: Float {
            switch self {
            case .listening: 0.09
            case .complete: 0.12
            case .attention: 0.10
            }
        }
    }

    static var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: preferenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    static func play(_ event: Event) {
        guard isEnabled else { return }
        let sound = sounds[event] ?? NSSound(named: NSSound.Name(event.name))
        guard let sound else { return }
        sounds[event] = sound
        sound.stop()
        sound.volume = event.volume
        sound.play()
    }
}
