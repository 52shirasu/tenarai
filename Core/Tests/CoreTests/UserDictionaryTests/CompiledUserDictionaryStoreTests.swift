@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@Test func rebuildCompiledUserDictionaryWritesSearchFiles() throws {
    let directoryURL = try makeTemporaryDirectoryURL()
    let charIDFileURL = try makeTemporaryCharIDFileURL(characters: "\0テストジショ")
    let entries = [
        DicdataElement(word: "テスト単語", ruby: "テスト", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
        DicdataElement(word: "辞書単語", ruby: "ジショ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    ]

    try CompiledUserDictionaryStore.rebuild(entries: entries, directoryURL: directoryURL, charIDFileURL: charIDFileURL)

    #expect(CompiledUserDictionaryStore.hasCompiledDictionary(at: directoryURL))
    #expect(!FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("metadata.json").path))
    #expect(!FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("fallback.json").path))
}

@Test func rebuildCompiledUserDictionarySkipsUnsupportedReadings() throws {
    let directoryURL = try makeTemporaryDirectoryURL()
    let charIDFileURL = try makeTemporaryCharIDFileURL(characters: "\0テスト")
    let entries = [
        DicdataElement(word: "外字単語", ruby: "\u{10FFFF}", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    ]

    try CompiledUserDictionaryStore.rebuild(entries: entries, directoryURL: directoryURL, charIDFileURL: charIDFileURL)

    #expect(!CompiledUserDictionaryStore.hasCompiledDictionary(at: directoryURL))
    #expect(!FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("metadata.json").path))
    #expect(!FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent("fallback.json").path))
}

@MainActor
@Test func compiledUserDictionaryCandidatesUseExportDirectory() throws {
    guard CompiledUserDictionaryStore.defaultCharIDFileURL() != nil else {
        return
    }
    let memoryURL = try makeTemporaryDirectoryURL()
    let dictionaryURL = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryURL)
    try CompiledUserDictionaryStore.rebuild(entries: [
        DicdataElement(word: "コーシー", ruby: "コーシー", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5),
        DicdataElement(word: "Cauchy", ruby: "コーシー", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    ], directoryURL: dictionaryURL)

    let manager = SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: memoryURL,
        containerURL: nil,
        context: .init(useZenzai: false)
    )
    manager.insertAtCursorPosition("こーしー", inputStyle: .direct)
    manager.requestSetCandidateWindowState(visible: true)

    switch manager.getCurrentCandidateWindow(inputState: .selecting) {
    case .selecting(let candidates, _), .composing(let candidates, _):
        let candidateTexts = candidates.map(\.text)
        #expect(candidateTexts.contains("コーシー"))
        #expect(candidateTexts.contains("Cauchy"))
    case .hidden:
        Issue.record("candidate window is hidden")
    }
}

@Test func mergedEntriesDropTrendWordsSharingPersonalReadings() throws {
    let personal = [
        DicdataElement(word: "自分の語", ruby: "バズル", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    ]
    let trend: [TrendWordsStore.Entry] = [
        .init(reading: "ばずる", word: "バズる"),
        .init(reading: "かくさん", word: "拡散")
    ]

    let merged = CompiledUserDictionaryStore.mergedEntries(personal: personal, trend: trend)

    #expect(merged.count == 2)
    #expect(merged[0].word == "自分の語")
    #expect(!merged.contains { $0.word == "バズる" })
    let added = try #require(merged.first { $0.word == "拡散" })
    #expect(added.ruby == "カクサン")
    #expect(added.lcid == CIDData.固有名詞.cid)
    #expect(added.rcid == CIDData.固有名詞.cid)
    #expect(added.mid == MIDData.一般.mid)
    #expect(added.value() == -5)
}

@Test func exportWritesTrendStampAndNeedsExportFollowsTrendFile() throws {
    let memoryURL = try makeTemporaryDirectoryURL()
    let trendDirectoryURL = try makeTemporaryDirectoryURL()
    let trendFileURL = trendDirectoryURL.appendingPathComponent("trend.tsv", isDirectory: false)
    try "かくさん\t拡散\n".write(to: trendFileURL, atomically: true, encoding: .utf8)
    let charIDFileURL = try makeTemporaryCharIDFileURL(characters: "\0カクサンバズル")

    #expect(CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryURL, trendFileURL: trendFileURL, trendEnabled: true))

    try CompiledUserDictionaryStore.export(
        memoryDirectoryURL: memoryURL,
        personal: [],
        trendFileURL: trendFileURL,
        trendEnabled: true,
        charIDFileURL: charIDFileURL
    )

    let directoryURL = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryURL)
    let stampURL = directoryURL.appendingPathComponent("trend.stamp", isDirectory: false)
    #expect(try String(contentsOf: stampURL, encoding: .utf8) == TrendWordsStore.stamp(for: trendFileURL, enabled: true))
    #expect(CompiledUserDictionaryStore.hasCompiledDictionary(at: directoryURL))
    #expect(!CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryURL, trendFileURL: trendFileURL, trendEnabled: true))
    // 設定を切り替えると書き出しが必要になる
    #expect(CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryURL, trendFileURL: trendFileURL, trendEnabled: false))

    try "かくさん\t拡散\nばずる\tバズる\n".write(to: trendFileURL, atomically: true, encoding: .utf8)
    #expect(CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryURL, trendFileURL: trendFileURL, trendEnabled: true))
}

@Test func needsExportIsFalseForEmptyDictionaryWithMatchingStamp() throws {
    let memoryURL = try makeTemporaryDirectoryURL()
    let trendFileURL = try makeTemporaryDirectoryURL().appendingPathComponent("trend.tsv", isDirectory: false)

    try CompiledUserDictionaryStore.export(
        memoryDirectoryURL: memoryURL,
        personal: [],
        trendFileURL: trendFileURL,
        trendEnabled: true
    )

    let directoryURL = CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryURL)
    #expect(!CompiledUserDictionaryStore.hasCompiledDictionary(at: directoryURL))
    #expect(!CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryURL, trendFileURL: trendFileURL, trendEnabled: true))
}

private func makeTemporaryDirectoryURL() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("CompiledUserDictionaryStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func makeTemporaryCharIDFileURL(characters: String) throws -> URL {
    let directoryURL = try makeTemporaryDirectoryURL()
    let fileURL = directoryURL.appendingPathComponent("charID.chid", isDirectory: false)
    try characters.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}
