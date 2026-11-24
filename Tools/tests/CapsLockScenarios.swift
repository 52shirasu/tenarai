import Cocoa
import Core
_ = NSApplication.shared
var checks = 0
for (key, lower) in [(UInt16(0), "a"), (46,"m"), (34,"i"), (31,"o"), (18,"1"), (49," ")] {
    for flags: NSEvent.ModifierFlags in [[], [.shift], [.option], [.control], [.command], [.shift,.option]] {
        let off = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: lower, charactersIgnoringModifiers: lower, isARepeat: false, keyCode: key)!
        let expected = off.characters(byApplyingModifiers: flags)
        let on = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(.capsLock), timestamp: 0, windowNumber: 0, context: nil, characters: lower.uppercased(), charactersIgnoringModifiers: lower.uppercased(), isARepeat: false, keyCode: key)!
        precondition(on.keyEventCore.characters == expected)
        precondition(on.keyEventCore.modifierFlags == off.keyEventCore.modifierFlags)
        precondition(on.keyEventCore.charactersIgnoringModifiers == off.characters(byApplyingModifiers: []))
        precondition(off.keyEventCore.characters == lower)
        checks += 1
    }
}
print("PASS \(checks) CapsLock normalization cases; Shift/Option/Control/Command and unmodified events")
