@testable import Core
import Foundation
import Testing
import KanaKanjiConverterModuleWithDefaultDictionary

/// Standard romaji: "nn" is ん and consumes both keys; ん followed by a na-row kana
/// needs a third n (konnnichiha). "hannei" must read はんえい (反映), not はんねい.
@Test func romanNStandardRules() {
    let pairs = [("hannei", "はんえい"), ("kinnen", "きんえn"), ("kinnenn", "きんえん"), ("kinnnen", "きんねn"),
                 ("konnnichiha", "こんにちは"), ("konnichiha", "こんいちは"),
                 ("konnani", "こんあに"), ("konnnani", "こんなに"),
                 ("kannou", "かんおう"), ("kannnou", "かんのう"),
                 ("sennyuu", "せんゆう"), ("sennnyuu", "せんにゅう"),
                 ("kanntan", "かんたn"), ("nn", "ん"), ("nna", "んあ"), ("nnna", "んな"),
                 ("xna", "んあ"), ("anna", "あんあ"), ("annna", "あんな"), ("kanji", "かんじ")]
    for style: InputStyle in [.roman2kana, .mapped(id: .defaultRomanToKana)] {
        for (raw, expected) in pairs {
            var sequential = ComposingText()
            for ch in raw { sequential.insertAtCursorPosition(String(ch), inputStyle: style) }
            #expect(sequential.convertTarget == expected, "\(raw): \(sequential.convertTarget)")
            var keyed = ComposingText()
            for ch in raw {
                keyed.insertAtCursorPosition([.init(piece: .key(intention: ch, input: ch, modifiers: []), inputStyle: style)])
            }
            #expect(keyed.convertTarget == expected)
            var batch = ComposingText()
            batch.insertAtCursorPosition(raw, inputStyle: style)
            #expect(batch.convertTarget == sequential.convertTarget)
        }
    }
}

@MainActor @Test func enterFinishesTrailingSingleNAsN() {
    for (raw, reading) in [("henkan", "へんかん"), ("gohenkan", "ごへんかん"), ("kantan", "かんたん")] {
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
            context: .init(useZenzai: false))
        manager.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        #expect(manager.convertTarget.hasSuffix("n"))
        manager.finishPendingRomajiN(inputStyle: .roman2kana)
        #expect(manager.convertTarget == reading)
        let committed = manager.commitMarkedText(inputState: .composing)
        #expect(!committed.contains("n"), "pending n leaked into \(committed)")
    }
    // Direct (Latin) input and already-finished readings are untouched.
    let latin = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
        context: .init(useZenzai: false))
    latin.insertAtCursorPosition("Japan", inputStyle: .direct)
    latin.finishPendingRomajiN(inputStyle: .direct)
    #expect(latin.convertTarget == "Japan")
    let finished = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
        context: .init(useZenzai: false))
    finished.insertAtCursorPosition("henkann", inputStyle: .roman2kana)
    let before = finished.convertTarget
    finished.finishPendingRomajiN(inputStyle: .roman2kana)
    #expect(finished.convertTarget == before)
}
