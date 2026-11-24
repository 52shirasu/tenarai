import Foundation
import Testing
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Core

@Test func japaneseTypoSingleEditMatrix() {
    for entry in JapaneseTypoCandidates.entries {
        let chars = Array(entry.roman)
        for i in chars.indices {
            var missing = chars; missing.remove(at: i)
            if JapaneseTypoCandidates.entries.contains(where: { $0.roman == String(missing) }) {
                #expect(JapaneseTypoCandidates.suggestions(raw: String(missing), reading: "").isEmpty)
            } else {
                #expect(JapaneseTypoCandidates.suggestions(raw: String(missing), reading: "").contains(entry.text))
            }
            var wrong = chars; wrong[i] = "x"
            #expect(JapaneseTypoCandidates.suggestions(raw: String(wrong), reading: "").contains(entry.text))
            var doubled = chars; doubled.insert(chars[i], at: i)
            #expect(JapaneseTypoCandidates.suggestions(raw: String(doubled), reading: "").contains(entry.text))
            if i + 1 < chars.count && chars[i] != chars[i + 1] {
                var swapped = chars; swapped.swapAt(i, i + 1)
                #expect(JapaneseTypoCandidates.suggestions(raw: String(swapped), reading: "").contains(entry.text))
            }
        }
    }
    #expect(JapaneseTypoCandidates.suggestions(raw: "おはようgざいます", reading: "おはようgざいます").contains("おはようございます"))
    for text in ["ohayougozaimasu", "Iphone", "サーバー", "", "https://example.com", String(repeating: "a", count: 10000)] {
        #expect(JapaneseTypoCandidates.suggestions(raw: text, reading: text).isEmpty)
    }
    #expect(!JapaneseTypoCandidates.oneEdit("abcdef", "badcfe"))
}

@MainActor @Test func japaneseTypoCandidateCommitUsesOriginalInputCount() {
    for raw in ["ohayougzaimasu", "ohayougozaiamsu", "arigatougozzaimasu"] {
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
            context: .init(useZenzai: false))
        manager.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        let unchanged = manager.convertTarget
        manager.update(requestRichCandidates: true)
        #expect(manager.convertTarget == unchanged)
        let expected = raw.hasPrefix("arigatou") ? "ありがとうございます" : "おはようございます"
        guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
              let index = candidates.firstIndex(where: { $0.text == expected }) else {
            Issue.record("Missing repaired Japanese candidate: \(raw)"); continue
        }
        #expect(candidates.contains { $0.text == unchanged })
        manager.requestSelectingRow(index)
        #expect(manager.commitMarkedText(inputState: .selecting) == expected)
        #expect(manager.isEmpty)
        manager.insertAtCursorPosition("ni", inputStyle: .roman2kana)
        #expect(manager.convertTarget == "に")
    }
}

@MainActor @Test func curatedPhraseCorrectionIsFirstSpaceCandidate() {
    for (raw, expected) in [("ohayougzaimasu", "おはようございます"), ("arigatougoziamasu", "ありがとうございます")] {
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
            context: .init(useZenzai: false))
        manager.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        manager.update(requestRichCandidates: true)
        guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
            Issue.record("No candidates: \(raw)"); continue
        }
        // The whole corrected phrase, not the first clause of the typo, is offered first.
        #expect(candidates.first?.text == expected)
        // The literal input stays available.
        #expect(candidates.contains { $0.text == manager.convertTarget })
    }
    // Correct input is never "corrected".
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
        context: .init(useZenzai: false))
    manager.insertAtCursorPosition("henkan", inputStyle: .roman2kana)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("No candidates"); return
    }
    #expect(candidates.first?.text != "おはようございます")
}
