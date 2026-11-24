@testable import Core
import Foundation
import Testing

@Test func trendWordsFileURLIsUnderTrendDirectory() {
    let root = URL(fileURLWithPath: "/tmp/TenaraiTrendTests", isDirectory: true)
    let url = TrendWordsStore.fileURL(applicationSupportDirectoryURL: root)
    #expect(url.path == "/tmp/TenaraiTrendTests/trend/trend.tsv")
}

@Test func trendWordsLoadReadsValidLinesAndIgnoresExtraColumns() throws {
    let url = try makeTrendFile("かくさん\t拡散\t123\textra\nばずる\tバズる\r\nとれんどわーど\tトレンドワード\n")
    let entries = TrendWordsStore.load(from: url)
    #expect(entries == [
        .init(reading: "かくさん", word: "拡散"),
        .init(reading: "ばずる", word: "バズる"),
        .init(reading: "とれんどわーど", word: "トレンドワード")
    ])
}

@Test func trendWordsLoadDropsInvalidLines() throws {
    let lines = [
        "カタカナ\t片仮名",       // 読みがカタカナ
        "abc\tエービーシー",     // 読みが英字
        "あい\t愛情",             // 読みが短すぎる
        "ばずる\tばずる",         // 表記が読みと同じ
        "ばずる",                 // 列が足りない
        "ばずる\t",               // 表記が空
        "ばずる\tバ\u{07}ズる",   // 表記に制御文字
        "ばずる\tバ",             // 表記が短すぎる
        String(repeating: "あ", count: 31) + "\t長すぎる読み",
        "ばずる\t" + String(repeating: "語", count: 31),
        "かくさん\t拡散"
    ]
    let url = try makeTrendFile(lines.joined(separator: "\n"))
    #expect(TrendWordsStore.load(from: url) == [.init(reading: "かくさん", word: "拡散")])
}

@Test func trendWordsLoadDeduplicatesAndKeepsOrder() throws {
    let url = try makeTrendFile("ばずる\tバズる\nかくさん\t拡散\nばずる\tバズる\tdup\nばずる\tBUZZ\n")
    #expect(TrendWordsStore.load(from: url) == [
        .init(reading: "ばずる", word: "バズる"),
        .init(reading: "かくさん", word: "拡散"),
        .init(reading: "ばずる", word: "BUZZ")
    ])
}

@Test func trendWordsLoadStopsAtMaximumEntries() throws {
    let lines = (0..<5_100).map { index in "ばずる\t語\(index)" }
    let url = try makeTrendFile(lines.joined(separator: "\n"))
    let entries = TrendWordsStore.load(from: url)
    #expect(entries.count == 5_000)
    #expect(entries.first?.word == "語0")
    #expect(entries.last?.word == "語4999")
}

@Test func trendWordsLoadIgnoresFilesOverTwoMegabytes() throws {
    let line = "ばずる\tバズる\n"
    let padding = String(repeating: "#", count: 2 * 1024 * 1024)
    let url = try makeTrendFile(line + padding)
    #expect(TrendWordsStore.load(from: url).isEmpty)
}

@Test func trendWordsLoadReturnsEmptyWhenFileIsMissing() throws {
    let directoryURL = try makeTrendTemporaryDirectoryURL()
    let url = directoryURL.appendingPathComponent("trend/trend.tsv", isDirectory: false)
    #expect(TrendWordsStore.load(from: url).isEmpty)
}

@Test func trendWordsStampReflectsSettingAndFile() throws {
    let directoryURL = try makeTrendTemporaryDirectoryURL()
    let url = directoryURL.appendingPathComponent("trend.tsv", isDirectory: false)

    #expect(TrendWordsStore.stamp(for: url, enabled: false) == "off")
    #expect(TrendWordsStore.stamp(for: url, enabled: true) == "none")

    try "ばずる\tバズる\n".write(to: url, atomically: true, encoding: .utf8)
    let first = TrendWordsStore.stamp(for: url, enabled: true)
    #expect(first != "none")
    #expect(first.hasPrefix("\(try Data(contentsOf: url).count)-"))
    #expect(TrendWordsStore.stamp(for: url, enabled: false) == "off")

    try "ばずる\tバズる\nかくさん\t拡散\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(TrendWordsStore.stamp(for: url, enabled: true) != first)
}

private func makeTrendTemporaryDirectoryURL() throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrendWordsStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func makeTrendFile(_ content: String) throws -> URL {
    let url = try makeTrendTemporaryDirectoryURL().appendingPathComponent("trend.tsv", isDirectory: false)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}
