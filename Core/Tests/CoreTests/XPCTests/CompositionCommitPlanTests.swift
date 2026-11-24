@testable import Core
import Foundation
import Testing

private func displayed(_ parts: [(String, ConverterMarkedText.FocusState)]) -> ConverterSessionSnapshot {
    ConverterSessionSnapshot(
        markedText: ConverterMarkedText(elements: parts.map { .init(content: $0.0, focus: $0.1) }, selectionRange: .init(location: NSNotFound, length: 0)),
        candidateWindow: .hidden,
        isEmpty: false,
        convertTarget: parts.map(\.0).joined()
    )
}

/// The reported bug: after Space→Enter committed the first clause, the second half
/// stays as marked text. A focus change then asks for a commit and IMK deactivates the
/// client immediately; the old asynchronous commit reply was discarded.
@Test func focusChangeAfterFirstClauseCommitInsertsRemainderImmediately() {
    let remainder = displayed([("散歩に行きます", .none)])
    #expect(CompositionCommitPlan.make(pendingKeyEvents: 0, displayed: remainder) == .insertDisplayedText("散歩に行きます"))
}

@Test func selectingStateCommitsFocusedAndUnfocusedParts() {
    let selecting = displayed([("今日は天気が良いので", .focused), ("さんぽにいきます", .unfocused)])
    #expect(CompositionCommitPlan.make(pendingKeyEvents: 0, displayed: selecting)
        == .insertDisplayedText("今日は天気が良いのでさんぽにいきます"))
}

@Test func keyEventsInFlightDeferToServer() {
    let stale = displayed([("ごへ", .none)])
    #expect(CompositionCommitPlan.make(pendingKeyEvents: 2, displayed: stale) == .askServer)
}

@Test func nothingDisplayedNothingToInsert() {
    #expect(CompositionCommitPlan.make(pendingKeyEvents: 0, displayed: nil) == .nothingToCommit)
    #expect(CompositionCommitPlan.make(pendingKeyEvents: 0, displayed: displayed([("", .none)])) == .nothingToCommit)
}
