@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Test func unconvertedKanaCommitIsNotLearned() {
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "ごへんかん", reading: "ごへんかん"))
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "ゴヘンカン", reading: "ごへんかん"))
}

@Test func pendingRomajiCommitIsNotLearned() {
    // A clause committed while a romaji consonant was still pending.
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "あs", reading: "あs"))
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "サンプルn", reading: "さんぷるn"))
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "ご返歌n", reading: "ごへんかn"))
}

@Test func convertedAndLatinCommitsAreStillLearned() {
    #expect(SegmentsManager.shouldLearnImplicitCommit(text: "誤変換", reading: "ごへんかん"))
    #expect(SegmentsManager.shouldLearnImplicitCommit(text: "今日は天気が良い", reading: "きょうはてんきがよい"))
    // Shift-started Latin words are entirely ASCII and remain learnable.
    #expect(SegmentsManager.shouldLearnImplicitCommit(text: "iPhone", reading: "Iphone"))
    #expect(!SegmentsManager.shouldLearnImplicitCommit(text: "", reading: ""))
}

@MainActor
@Test func commitWithoutLearningStillReturnsAndClearsComposition() {
    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false)
    )
    manager.insertAtCursorPosition("henkan", inputStyle: .roman2kana)
    let text = manager.commitMarkedText(inputState: .composing, learn: false)
    #expect(!text.isEmpty)
    #expect(manager.isEmpty)
}
