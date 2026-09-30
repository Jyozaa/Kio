import Foundation

/// Recognizes an Option+Command modifier-only chord without consuming keyboard input.
public struct ModifierChordRecognizer: Sendable {
    private var tracking = false
    private var sawBoth = false
    private var invalid = false

    public init() {}

    /// Call for every flags-changed event using aggregate left/right modifier flags.
    /// Returns true once, after both modifiers have been released, only if no key occurred.
    public mutating func modifiersChanged(optionDown: Bool, commandDown: Bool) -> Bool {
        let anyTargetModifier = optionDown || commandDown
        if anyTargetModifier && !tracking {
            tracking = true
            sawBoth = false
            invalid = false
        }
        if tracking && optionDown && commandDown {
            sawBoth = true
        }
        guard tracking && !anyTargetModifier else { return false }
        let triggered = sawBoth && !invalid
        reset()
        return triggered
    }

    /// Any ordinary key during the modifier sequence disqualifies the chord.
    public mutating func nonModifierKeyDown() {
        if tracking { invalid = true }
    }

    /// Use when the event tap is interrupted so a missing release cannot trigger later.
    public mutating func reset() {
        tracking = false
        sawBoth = false
        invalid = false
    }
}
