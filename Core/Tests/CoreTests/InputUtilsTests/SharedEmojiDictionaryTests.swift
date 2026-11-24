import Testing
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Core

@Test func sharedEmojiDictionaryRetainsSearchResults() {
    let fresh = TextReplacer.withDefaultEmojiDictionary()
    for query in ["ねこ", "はーと", "えがお", "ありがとう", "いぬ"] {
        let expected = fresh.getSearchResult(query: query, target: [.emoji]).map(\.text)
        #expect(!expected.isEmpty)
        for _ in 0..<3 {
            #expect(SegmentsManager.bundledTextReplacer.getSearchResult(query: query, target: [.emoji]).map(\.text) == expected)
        }
    }
}
