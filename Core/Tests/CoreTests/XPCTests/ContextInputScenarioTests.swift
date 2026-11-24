import Foundation
import Testing
@testable import Core
import LearningCore

@Test func contextUnavailableNeverBecomesDocumentStart() {
    let unavailable = NSRange(location: NSNotFound, length: 0)
    #expect(TextContextBounds.surrounding(marked: unavailable, selected: unavailable, length: 42, limit: 200) == nil)
    #expect(TextContextBounds.surrounding(marked: unavailable, selected: NSRange(location: Int.max - 1, length: 12), length: 42, limit: 200) == nil)
    let empty = TextContextBounds.surrounding(marked: unavailable, selected: NSRange(location: 0, length: 0), length: 0, limit: 200)
    #expect(empty?.left.length == 0)
    #expect(empty?.right.length == 0)
}

@Test func markedTextAndCommittedEmojiAreKeptSeparate() throws {
    let left = "数学😀の行列\n", marked = "こうれつ", right = "を計算する"
    let length = (left + marked + right).utf16.count
    let ranges = try #require(TextContextBounds.surrounding(
        marked: NSRange(location: left.utf16.count, length: marked.utf16.count),
        selected: NSRange(location: length, length: 0), length: length, limit: 200))
    let document = (left + marked + right) as NSString
    #expect(document.substring(with: ranges.left) == left)
    #expect(document.substring(with: ranges.right) == right)
}

@Test func pasteReplacementLearnsWeaklyThenEditDeleteAndLateResult() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let original = "前置き 古い文 終わり" as NSString
    let selection = original.range(of: "古い文")
    let paste = try #require(PendingPaste(selection: selection, documentLength: original.length))
    let inserted = "Dockerのサーバー😀と行列"
    let replaced = original.replacingCharacters(in: selection, with: inserted) as NSString
    let range = try #require(paste.insertedRange(selection: NSRange(location: selection.location + inserted.utf16.count, length: 0), documentLength: replaced.length))
    let actual = replaced.substring(with: range)
    for _ in 0..<3 {
        let job = try await store.enqueue(actual, origin: .pasted)
        try await store.complete(job, observations: LocalExtractor.extract(actual, origin: .pasted))
    }
    let initial = await store.tendencies()
    #expect(!initial.isEmpty)
    #expect(initial.allSatisfy { $0.evidence == 0.25 && $0.kind != .spelling })
    for _ in 0..<2 {
        let job = try await store.enqueue("サーバー", origin: .typed)
        try await store.complete(job, observations: LocalExtractor.extract(job.text, origin: .typed))
    }
    #expect(LocalExtractor.profile(await store.tendencies(), hasContext: false).contains("サーバー"))
    #expect(LocalExtractor.profile(await store.tendencies(), hasContext: true).isEmpty)
    let late = try await store.enqueue("サーバー", origin: .typed)
    try await store.edit(key: "spelling:server", value: "サーバ")
    #expect(try await store.complete(late, observations: LocalExtractor.extract(late.text, origin: .typed)) == false)
    let reloaded = try LearningStore(directory: directory)
    #expect(await reloaded.tendencies().first { $0.key == "spelling:server" }?.value == "サーバ")
    try await store.deleteAll()
    #expect(await store.tendencies().isEmpty)
    #expect(try await store.pending().isEmpty)
}

@Test func cancelledPasteIsIgnoredAndLargePasteIsRecognized() throws {
    let paste = try #require(PendingPaste(selection: NSRange(location: 5, length: 0), documentLength: 10))
    #expect(paste.insertedRange(selection: NSRange(location: 5, length: 0), documentLength: 10) == nil)
    #expect(paste.insertedRange(selection: NSRange(location: 8, length: 0), documentLength: 10) == nil)
    #expect(paste.insertedRange(selection: NSRange(location: 9005, length: 0), documentLength: 9010) == NSRange(location: 5, length: 9000))
    #expect(paste.insertedRange(selection: NSRange(location: NSNotFound, length: 0), documentLength: 10) == nil)
}
