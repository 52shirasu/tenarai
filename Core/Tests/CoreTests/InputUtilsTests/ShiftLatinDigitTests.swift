import Core
import Foundation
import KanaKanjiConverterModule
import Testing

/// Real digit key codes: 1...9, 0. A digit with keyCode 0 is `.input`, never `.number`.
private let digitKeyCodes: [(String, UInt16)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]

private func digitEvent(_ digit: String, keyCode: UInt16) -> KeyEventCore {
    KeyEventCore(modifierFlags: [], characters: digit, charactersIgnoringModifiers: digit, keyCode: keyCode)
}

private func event(
    _ state: InputState,
    _ keyEvent: KeyEventCore,
    shiftStartedLatinComposition: Bool,
    liveConversionEnabled: Bool = true
) -> (ClientAction, ClientActionCallback) {
    state.event(
        eventCore: keyEvent,
        userAction: UserAction.getUserAction(eventCore: keyEvent, inputLanguage: .japanese),
        inputLanguage: .japanese,
        liveConversionEnabled: liveConversionEnabled,
        enableDebugWindow: false,
        enableSuggestion: false,
        shiftStartedLatinComposition: shiftStartedLatinComposition
    )
}

@Suite("Digits after a Shift-started Latin composition (\"Ab1\", \"Ab 1\")")
struct ShiftLatinDigitTests {
    @Test func digitKeyCodesAreNumbers() {
        for (digit, keyCode) in digitKeyCodes {
            guard case .number(let number) = UserAction.getUserAction(eventCore: digitEvent(digit, keyCode: keyCode), inputLanguage: .japanese) else {
                Issue.record("keyCode \(keyCode) is not a number")
                continue
            }
            #expect(number.inputString == digit)
        }
    }

    /// "Ab1": no Space, the digit joins the Latin composition.
    @Test func digitWhileComposingLatinIsAppended() {
        for (digit, keyCode) in digitKeyCodes {
            let (action, callback) = event(.composing, digitEvent(digit, keyCode: keyCode), shiftStartedLatinComposition: true)
            guard case .appendPieceToMarkedText(let pieces) = action, case .fallthrough = callback else {
                Issue.record("\(digit): \(action)")
                continue
            }
            #expect(pieces == [.character(Character(digit))])
        }
    }

    /// "Ab 1": Space opened the Latin candidates; the digit must not pick a candidate.
    @Test func digitWhileSelectingLatinCandidatesCommitsAndKeepsTheDigit() {
        for live in [true, false] {
            for (digit, keyCode) in digitKeyCodes {
                let (action, callback) = event(.selecting, digitEvent(digit, keyCode: keyCode), shiftStartedLatinComposition: true, liveConversionEnabled: live)
                guard case .commitMarkedTextAndInsertAndAppendPieceToMarkedText(let text, let pieces) = action,
                      case .transition(.composing) = callback else {
                    Issue.record("\(digit) live=\(live): \(action)")
                    continue
                }
                #expect(text == " ")
                #expect(pieces == [.character(Character(digit))])
            }
        }
    }

    /// Japanese candidate selection keeps number keys as candidate shortcuts.
    @Test func digitWhileSelectingJapaneseCandidatesStillSelectsByNumber() {
        for (digit, keyCode) in digitKeyCodes where digit != "0" {
            let (action, _) = event(.selecting, digitEvent(digit, keyCode: keyCode), shiftStartedLatinComposition: false)
            guard case .selectNumberCandidate(let number) = action else {
                Issue.record("\(digit): \(action)")
                continue
            }
            #expect(String(number) == digit)
        }
        let (zero, _) = event(.selecting, digitEvent("0", keyCode: 29), shiftStartedLatinComposition: false)
        guard case .commitMarkedTextAndAppendPieceToMarkedText = zero else {
            Issue.record("0: \(zero)")
            return
        }
    }

    /// Space keeps its meaning in both kinds of composition.
    @Test func spaceStillOpensCandidates() {
        let space = KeyEventCore(modifierFlags: [], characters: " ", charactersIgnoringModifiers: " ", keyCode: 49)
        for latin in [true, false] {
            let (action, callback) = event(.composing, space, shiftStartedLatinComposition: latin)
            guard case .enterCandidateSelectionMode = action, case .transition(.selecting) = callback else {
                Issue.record("latin=\(latin): \(action)")
                continue
            }
        }
    }

    /// The client's router must hand these digits to the server, not to the app.
    @Test func routerSendsDigitsToServerWhileSelecting() {
        for (digit, keyCode) in digitKeyCodes {
            #expect(ConverterClientEventRouter.disposition(
                event: digitEvent(digit, keyCode: keyCode),
                context: .init(acknowledgedInputState: ConverterInputState(.selecting))
            ) == .sendToServer)
        }
    }
}

@Suite("Password fields (Secure Event Input)")
struct SecureInputPolicyTests {
    @Test func noSecureInputKeepsTheInputMethod() {
        #expect(!SecureInputPolicy.bypassesInputMethod(secureInputEnabled: false, ownerPID: 42, clientPIDs: [42]))
    }

    @Test func clientsOwnSecureInputBypassesTheInputMethod() {
        #expect(SecureInputPolicy.bypassesInputMethod(secureInputEnabled: true, ownerPID: 42, clientPIDs: [7, 42]))
    }

    /// Terminal's Secure Keyboard Entry or a password manager must not disable Japanese input in Safari.
    @Test func anotherAppsSecureInputKeepsTheInputMethod() {
        #expect(!SecureInputPolicy.bypassesInputMethod(secureInputEnabled: true, ownerPID: 99, clientPIDs: [42]))
    }

    @Test func unknownOwnerIsTreatedAsSecure() {
        #expect(SecureInputPolicy.bypassesInputMethod(secureInputEnabled: true, ownerPID: nil, clientPIDs: [42]))
        #expect(SecureInputPolicy.bypassesInputMethod(secureInputEnabled: true, ownerPID: 42, clientPIDs: []))
    }
}

@Suite("Symbols in a Shift-started Latin composition")
struct LatinCompositionInputTests {
    /// Shift+1 on a US keyboard in Japanese mode: intention "！", typed "!".
    @Test func symbolsKeepTheTypedCharacter() {
        let shiftOne = KeyEventCore(modifierFlags: [.shift], characters: "!", charactersIgnoringModifiers: "!", keyCode: 18)
        guard case .input(let pieces) = UserAction.getUserAction(eventCore: shiftOne, inputLanguage: .japanese) else {
            Issue.record("Shift+1 is not input")
            return
        }
        #expect(LatinCompositionInput.typed(pieces) == [.character("!")])
    }

    @Test func charactersAreUnchanged() {
        #expect(LatinCompositionInput.typed([.character("a"), .compositionSeparator]) == [.character("a"), .compositionSeparator])
    }
}
