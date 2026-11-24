import Foundation
import Testing
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Core

@MainActor @Test func realSpellingTypoMatrix() throws {
    let words = ["iPhone", "Docker", "Server", "Apple", "MacBook", "Keyboard", "Computer", "Network", "Database", "Python", "Swift", "Windows", "Browser", "Package", "Project", "Message", "Discord", "ChatGPT", "Vikunja", "Forgejo"]
    var rows: [[String: String]] = []
    var elapsed: [Double] = []
    for word in words {
        let chars = Array(word)
        var cases: [String: String] = [word: "correct"]
        // Every internal position: missing, doubled, replaced, adjacent swapped.
        for i in 1..<chars.count {
            var missing = chars; missing.remove(at: i); cases[String(missing)] = "missing"
            var doubled = chars; doubled.insert(chars[i], at: i); cases[String(doubled)] = "doubled"
            var replaced = chars; replaced[i] = chars[i] == "x" ? "z" : "x"; cases[String(replaced)] = "replaced"
            if i + 1 < chars.count, chars[i] != chars[i + 1] {
                var swapped = chars; swapped.swapAt(i, i + 1); cases[String(swapped)] = "swapped"
            }
        }
        for (input, kind) in cases.sorted(by: { $0.key < $1.key }) {
            let start = Date()
            let candidates = LatinConversionCandidates.words(for: input)
            elapsed.append(Date().timeIntervalSince(start) * 1000)
            #expect(candidates.contains(input), "Original lost: \(input)")
            #expect(candidates.count <= 20)
            #expect(Set(candidates).count == candidates.count)
            #expect(!candidates.contains(""))
            let hit = candidates.contains { $0.lowercased() == word.lowercased() }
            rows.append(["expected": word, "input": input, "kind": kind, "hit": String(hit), "candidates": candidates.joined(separator: " | ")])
        }
    }
    for input in ["", "日本語", "emoji😀", "two words", "a/b", String(repeating: "A", count: 129)] {
        #expect(LatinConversionCandidates.words(for: input) == [input])
    }
    for input in ["A", "I", "X", "123", "A1", "MAC", "Docker", "Apple", "sever", "Don't", "Wi-Fi"] {
        #expect(LatinConversionCandidates.words(for: input).contains(input))
    }
    elapsed.sort()
    let typoRows = rows.filter { $0["kind"] != "correct" }
    print("TYPO_MATRIX cases=\(rows.count) typo_hits=\(typoRows.filter { $0["hit"] == "true" }.count)/\(typoRows.count) latency_ms p50=\(elapsed[elapsed.count/2]) p95=\(elapsed[Int(Double(elapsed.count)*0.95)]) max=\(elapsed.last!)")
    if let path = ProcessInfo.processInfo.environment["TYPO_MATRIX_REPORT"] {
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}

@Test func personalNamesCoverMissingSystemVocabulary() {
    let entries: [Config.UserDictionaryEntry] = [.init(word: "Vikunja", reading: "びくんじゃ"), .init(word: "Forgejo", reading: "ふぉーじぇほ")]
    for entry in entries {
        let chars = Array(entry.word)
        for i in 1..<chars.count {
            var missing = chars; missing.remove(at: i)
            var doubled = chars; doubled.insert(chars[i], at: i)
            var replaced = chars; replaced[i] = "x"
            var swapped = chars
            if i + 1 < chars.count { swapped.swapAt(i, i + 1) }
            for input in [String(missing), String(doubled), String(replaced), String(swapped)] {
                let result = LatinConversionCandidates.personalized(input: input, base: [input], entries: entries)
                #expect(result.contains(entry.word), "Missing personal name: \(input)")
                #expect(result.contains(input))
                #expect(Set(result).count == result.count)
            }
        }
    }
    let result = LatinConversionCandidates.personalized(input: "Vikunaj", base: ["Vikunaj"], entries: entries)
    #expect(result.first == "Vikunaj")
    #expect(result.contains("ビクンジャ"))
    #expect(!result.contains("Forgejo"))
    #expect(LatinConversionCandidates.personalized(input: "Vikunaj", base: ["Vikunaj"], entries: []).count == 1)
}

@MainActor @Test func onlyExplicitCommittedLatinSelectionIsLearned() {
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
        context: .init(useZenzai: false))
    var learned: [String] = []
    manager.onExplicitLatinCommit = { learned.append($0) }
    manager.defersLatinConversion = true
    manager.insertAtCursorPosition("Vikunja", inputStyle: .direct)
    _ = manager.commitMarkedText(inputState: .composing)
    #expect(learned.isEmpty)
    manager.defersLatinConversion = true
    manager.insertAtCursorPosition("Vikunja", inputStyle: .direct)
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
          let index = candidates.firstIndex(where: { $0.text == "Vikunja" }) else { Issue.record("Missing original"); return }
    manager.requestSelectingRow(index)
    _ = manager.commitMarkedText(inputState: .selecting)
    #expect(learned == ["Vikunja"])
    manager.defersLatinConversion = true
    manager.insertAtCursorPosition("Forgejo", inputStyle: .direct)
    manager.update(requestRichCandidates: true)
    manager.requestSelectingRow(0)
    manager.requestSetCandidateWindowState(visible: false)
    _ = manager.commitMarkedText(inputState: .composing)
    #expect(learned == ["Vikunja"])
}
