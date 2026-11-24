import Foundation
import Testing
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Core

@Test func timeCandidateBounds() {
    for (input, expected) in [("1230", "12:30"), ("930", "09:30"), ("0000", "00:00"), ("2359", "23:59"), ("１２３０", "12:30")] {
        #expect(DateTimeCandidates.suggestions(reading: input).contains(expected))
    }
    for input in ["2400", "1260", "9999", "12", "12345", "-930", "12:30", "1230円", "今日は", "", String(repeating: "1", count: 1000)] {
        #expect(DateTimeCandidates.suggestions(reading: input).isEmpty)
    }
}

@Test func relativeDateBoundaries() {
    let utc = TimeZone(secondsFromGMT: 0)!
    let formatter = ISO8601DateFormatter()
    for (instant, reading, expected) in [
        ("2026-12-31T12:00:00Z", "あした", "2027/01/01"),
        ("2024-02-28T12:00:00Z", "あした", "2024/02/29"),
        ("2025-02-28T12:00:00Z", "あさって", "2025/03/02"),
        ("2026-01-01T12:00:00Z", "きのう", "2025/12/31"),
        ("2026-01-01T12:00:00Z", "おととい", "2025/12/30")
    ] {
        #expect(DateTimeCandidates.suggestions(reading: reading, now: formatter.date(from: instant)!, timeZone: utc).contains(expected))
    }
    let now = formatter.date(from: "2026-09-24T16:00:00Z")!
    #expect(DateTimeCandidates.suggestions(reading: "今日", now: now, timeZone: TimeZone(identifier: "Asia/Tokyo")!).contains("2026/09/25"))
    #expect(DateTimeCandidates.suggestions(reading: "きょう", now: now, timeZone: utc).contains("9月24日（木）"))
    let dst = formatter.date(from: "2026-03-08T07:30:00Z")!
    #expect(DateTimeCandidates.suggestions(reading: "あした", now: dst, timeZone: TimeZone(identifier: "America/New_York")!).contains("2026/03/09"))
}

@MainActor @Test func dateTimeCommitAndContinue() {
    for raw in ["1230", "930", "kyou", "ashita", "kinou", "asatte"] {
        let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
            applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
            context: .init(useZenzai: false))
        manager.insertAtCursorPosition(raw, inputStyle: .roman2kana)
        let original = manager.convertTarget
        let expected = DateTimeCandidates.suggestions(reading: original)[0]
        manager.update(requestRichCandidates: true)
        #expect(manager.convertTarget == original)
        guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting),
              let index = candidates.firstIndex(where: { $0.text == expected }) else {
            Issue.record("Missing date/time candidate for \(raw)"); continue
        }
        print("DATE_TIME_RANK raw=\(raw) index=\(index) first=\(candidates.prefix(9).map(\.text))")
        #expect(index <= 1)
        for spelling in DateTimeCandidates.suggestions(reading: original) {
            #expect(candidates.prefix(5).contains { $0.text == spelling })
            #expect(candidates.filter { $0.text == spelling }.count == 1)
        }
        #expect(candidates.contains { $0.text == original })
        manager.requestSelectingRow(index)
        #expect(manager.commitMarkedText(inputState: .selecting) == expected)
        #expect(manager.isEmpty)
        manager.insertAtCursorPosition("ni", inputStyle: .roman2kana)
        #expect(manager.convertTarget == "に")
    }
}
