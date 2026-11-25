import Core
import Testing

private func disposition(
    event: KeyEventCore,
    state: ConverterInputState = .none,
    language: InputLanguage = .japanese,
    hasPendingKeyEvents: Bool = false
) -> ConverterClientEventDisposition {
    ConverterClientEventRouter.disposition(
        event: event,
        context: .init(
            acknowledgedInputState: state,
            acknowledgedInputLanguage: language,
            hasPendingKeyEvents: hasPendingKeyEvents
        )
    )
}

@Test func printableJapaneseInputIsSentToServer() {
    #expect(
        disposition(
            event: KeyEventCore(
                modifierFlags: [],
                characters: "a",
                charactersIgnoringModifiers: "a",
                keyCode: 0
            )
        ) == .sendToServer
    )
}

@Test func backspaceFallsThroughWhenAcknowledgedStateIsEmpty() {
    #expect(
        disposition(
            event: KeyEventCore(
                modifierFlags: [],
                characters: nil,
                charactersIgnoringModifiers: nil,
                keyCode: 51
            )
        ) == .fallthroughToApplication
    )
}

@Test func backspaceIsConsumedWhileEarlierKeyEventIsPending() {
    #expect(
        disposition(
            event: KeyEventCore(
                modifierFlags: [],
                characters: nil,
                charactersIgnoringModifiers: nil,
                keyCode: 51
            ),
            hasPendingKeyEvents: true
        ) == .sendToServer
    )
}

@Test func commandShortcutAlwaysFallsThroughWhileServerIsDelayed() {
    #expect(
        disposition(
            event: KeyEventCore(
                modifierFlags: [.command],
                characters: "c",
                charactersIgnoringModifiers: "c",
                keyCode: 8
            ),
            state: .composing,
            hasPendingKeyEvents: true
        ) == .fallthroughToApplication
    )
}

@Test func unknownControlShortcutIsConsumedOnlyDuringComposition() {
    let event = KeyEventCore(
        modifierFlags: [.control],
        characters: "q",
        charactersIgnoringModifiers: "q",
        keyCode: 12
    )

    #expect(disposition(event: event) == .fallthroughToApplication)
    #expect(disposition(event: event, state: .composing) == .sendToServer)
}

@Test func commandEnterCommitsDisplayedCompositionBeforeFallingThrough() {
    func event(_ flags: KeyEventCore.ModifierFlag, _ keyCode: UInt16, _ characters: String = "\r") -> KeyEventCore {
        KeyEventCore(modifierFlags: flags, characters: characters, charactersIgnoringModifiers: characters, keyCode: keyCode)
    }
    #expect(ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([.command], 0x24)))
    #expect(ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([.command], 0x4C)))
    #expect(ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([.command, .shift], 0x24)))
    // Plain Enter is the server's commit; other Command shortcuts leave the composition alone.
    #expect(!ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([], 0x24)))
    #expect(!ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([.command], 8, "c")))
    #expect(!ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event([.control], 0x24)))
}
