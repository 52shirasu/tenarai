@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

private func makeSegmentsManager() -> SegmentsManager {
    SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false)
    )
}

@MainActor
private func selection(_ manager: SegmentsManager) -> (texts: [String], index: Int?)? {
    if case .selecting(let candidates, let index) = manager.getCurrentCandidateWindow(inputState: .selecting) {
        return (candidates.map(\.text), index)
    }
    return nil
}

/// Opening the list, moving to a later row and committing it must not leave that row
/// selected for the next composition (2026-11-19: "よう" opened at its third row).
@MainActor
@Test func listOpensAtFirstRowAfterALaterRowWasCommitted() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    #expect(selection(manager)?.index == 0)
    manager.requestSelectingNextCandidate()
    manager.requestSelectingNextCandidate()
    #expect(selection(manager)?.index == 2)
    let committed = try #require(manager.selectedCandidate)
    manager.prefixCandidateCommited(committed, leftSideContext: "")
    #expect(manager.isEmpty)
    #expect(manager.selectedCandidate == nil)

    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    let reopened = try #require(selection(manager))
    #expect(reopened.index == 0)
    #expect(manager.selectedCandidate?.text == reopened.texts.first)
}

/// Leaving the list with Escape keeps the composition; reopening starts at the top.
@MainActor
@Test func listOpensAtFirstRowAfterItWasClosedWithoutCommit() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kikai", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    manager.requestSelectingNextCandidate()
    manager.requestSelectingNextCandidate()
    manager.requestSetCandidateWindowState(visible: false)
    manager.openCandidateList(inputStyle: .roman2kana)
    #expect(selection(manager)?.index == 0)
}

/// After a segment edit and clause-by-clause commits the emptied text kept its cursor
/// position; the next key then took a negative prefix and aborted the helper.
@MainActor
@Test func typingAfterSegmentEditedCompositionWasCommittedDoesNotCrash() async throws {
    let manager = makeSegmentsManager()
    manager.insertAtCursorPosition("kyouhaame", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    manager.editSegment(count: -1)
    manager.requestSelectingNextCandidate()
    var guardCount = 0
    while !manager.isEmpty, guardCount < 10 {
        _ = manager.getCurrentCandidateWindow(inputState: .selecting)
        let candidate = try #require(manager.selectedCandidate)
        manager.prefixCandidateCommited(candidate, leftSideContext: "")
        guardCount += 1
    }
    #expect(manager.isEmpty)
    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    let reopened = try #require(selection(manager))
    #expect(reopened.index == 0)
    #expect(!reopened.texts.isEmpty)
    // The edited-range mode must not leak into the new composition's list.
    manager.insertAtCursorPosition("kyouhaame", inputStyle: .roman2kana)
}

/// Only a commit of a row other than the first is reported as a correction.
@MainActor
@Test func committingALaterRowReportsACorrection() async throws {
    let manager = makeSegmentsManager()
    var reports: [(reading: String, shown: String, chosen: String, index: Int)] = []
    manager.onCorrection = { reading, shown, chosen, _, _, index in
        reports.append((reading, shown, chosen, index))
    }
    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    // Showing the list is what selects its first row.
    #expect(selection(manager)?.index == 0)
    let first = try #require(manager.selectedCandidate)
    manager.prefixCandidateCommited(first, leftSideContext: "")
    #expect(reports.isEmpty)

    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    let shown = try #require(selection(manager)?.texts.first)
    manager.requestSelectingNextCandidate()
    manager.requestSelectingNextCandidate()
    let chosen = try #require(manager.selectedCandidate)
    manager.prefixCandidateCommited(chosen, leftSideContext: "")
    if chosen.text != shown {
        #expect(reports.count == 1)
        #expect(reports.first?.reading == "よう")
        #expect(reports.first?.shown == shown)
        #expect(reports.first?.chosen == chosen.text)
        #expect(reports.first?.index == 2)
    }

    manager.suppressesLearning = true
    manager.insertAtCursorPosition("you", inputStyle: .roman2kana)
    manager.openCandidateList(inputStyle: .roman2kana)
    manager.requestSelectingNextCandidate()
    let excluded = try #require(manager.selectedCandidate)
    let before = reports.count
    manager.prefixCandidateCommited(excluded, leftSideContext: "")
    #expect(reports.count == before)
}
