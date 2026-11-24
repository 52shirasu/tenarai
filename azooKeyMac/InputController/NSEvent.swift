import Cocoa
import Core

extension NSEvent {
    /// Re-translate with the active keyboard layout, preserving Shift/Option.
    /// Lowercasing would corrupt Shift input and non-US layouts.
    var charactersIgnoringCapsLock: String? {
        modifierFlags.contains(.capsLock)
            ? characters(byApplyingModifiers: modifierFlags.subtracting(.capsLock))
            : characters
    }

    var keyEventCore: KeyEventCore {
        KeyEventCore(
            modifierFlags: .init(from: self.modifierFlags),
            characters: self.charactersIgnoringCapsLock,
            charactersIgnoringModifiers: self.modifierFlags.contains(.capsLock)
                ? self.characters(byApplyingModifiers: []) : self.charactersIgnoringModifiers,
            keyCode: self.keyCode
        )
    }
}

/// NSEvent.ModifierFlagsとKeyEventCore.ModifierFlagの相互変換
extension KeyEventCore.ModifierFlag {
    public init(from nsModifiers: NSEvent.ModifierFlags) {
        var flags: KeyEventCore.ModifierFlag = []
        if nsModifiers.contains(.control) {
            flags.insert(.control)
        }
        if nsModifiers.contains(.option) {
            flags.insert(.option)
        }
        if nsModifiers.contains(.shift) {
            flags.insert(.shift)
        }
        if nsModifiers.contains(.command) {
            flags.insert(.command)
        }
        self = flags
    }

    public var nsModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) {
            flags.insert(.control)
        }
        if contains(.option) {
            flags.insert(.option)
        }
        if contains(.shift) {
            flags.insert(.shift)
        }
        if contains(.command) {
            flags.insert(.command)
        }
        return flags
    }
}
