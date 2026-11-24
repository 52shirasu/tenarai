import Foundation
import Testing
@testable import TrendWords

/// 2026-11-23 12:00 UTC（前月から 3 か月: 2026-10, 2026-09, 2026-08）
private let now = Date(timeIntervalSince1970: 1_795_435_200)
private let months = [(2026, 10), (2026, 9), (2026, 8)]

private struct Environment {
    var rootURL: URL
    var loudsURL: URL
    var trendDirectoryURL: URL { self.rootURL.appendingPathComponent("trend", isDirectory: true) }
    var trendFileURL: URL { self.trendDirectoryURL.appendingPathComponent("trend.tsv") }
    var statusFileURL: URL { self.trendDirectoryURL.appendingPathComponent("status.json") }

    func options(fetcher: FakeFetcher, enabled: Bool = true, force: Bool = false) -> TrendWordsUpdate.Options {
        .init(
            force: force,
            loudsDirectoryURL: self.loudsURL,
            applicationSupportDirectoryURL: self.rootURL,
            isEnabled: { enabled },
            fetcher: fetcher,
            now: { now }
        )
    }

    func workingDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: self.trendDirectoryURL.path)) ?? [])
            .filter { $0.hasPrefix("updating-") }
    }

    func status() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: self.statusFileURL)) as! [String: Any]
    }

    func writeOldList(modified: Date) throws {
        try FileManager.default.createDirectory(at: self.trendDirectoryURL, withIntermediateDirectories: true)
        try Data("ふるい\t古い一覧\t1\t1\n".utf8).write(to: self.trendFileURL)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: self.trendFileURL.path)
    }

    func oldListIsIntact() -> Bool {
        (try? String(contentsOf: self.trendFileURL, encoding: .utf8)) == "ふるい\t古い一覧\t1\t1\n"
    }
}

private func makeEnvironment() throws -> Environment {
    let rootURL = try makeTemporaryDirectoryURL()
    let loudsURL = rootURL.appendingPathComponent("louds", isDirectory: true)
    try FileManager.default.createDirectory(at: loudsURL, withIntermediateDirectories: true)
    return Environment(rootURL: rootURL, loudsURL: loudsURL)
}

/// `wordCount` 語が採用される材料。`availableMonths` の月だけ閲覧上位を返す
private func makeFetcher(wordCount: Int = 320, availableMonths: Int = 3) -> FakeFetcher {
    var dictionary = ""
    var articles: [(String, Int)] = []
    for index in 0..<wordCount {
        dictionary += "とれんど /トレンド\(index)/\n"
        articles.append(("トレンド\(index)", 10_000 - index))
    }
    var responses: [URL: Data] = [TrendWordsDownloader.readingDictionaryURL: Data(dictionary.utf8)]
    for (year, month) in months.prefix(availableMonths) {
        responses[TrendWordsDownloader.pageviewsURL(year: year, month: month)] = pageviewsJSON(articles)
    }
    return FakeFetcher(responses: responses)
}

private func permissions(_ url: URL) throws -> Int {
    try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

@Test func disabledSettingSkipsWithoutFetching() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-30 * 24 * 60 * 60))
    let fetcher = makeFetcher()
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher, enabled: false))
    #expect(result.outcome == .skippedDisabled)
    #expect(fetcher.requestedURLs.isEmpty)
    #expect(environment.oldListIsIntact())
    #expect(try environment.status()["result"] as? String == "skipped-disabled")
}

@Test func freshListSkipsWithoutFetching() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-5 * 24 * 60 * 60))
    let fetcher = makeFetcher()
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher))
    #expect(result.outcome == .skippedFresh)
    #expect(fetcher.requestedURLs.isEmpty)
    #expect(environment.oldListIsIntact())
    #expect(try environment.status()["result"] as? String == "skipped-fresh")
}

@Test func forceIgnoresFreshness() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-60))
    let fetcher = makeFetcher()
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher, force: true))
    #expect(result.outcome == .updated)
    #expect(!fetcher.requestedURLs.isEmpty)
}

@Test func successfulUpdateWritesListAndStatus() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-7 * 24 * 60 * 60))
    let fetcher = makeFetcher()
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher))

    #expect(result == .init(outcome: .updated, words: 320, excluded: 0, months: ["2026-08", "2026-09", "2026-10"]))
    let lines = try String(contentsOf: environment.trendFileURL, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 320)
    #expect(lines.first == "とれんど\tトレンド0\t30000\t3")
    #expect(try permissions(environment.trendFileURL) == 0o600)
    #expect(try permissions(environment.statusFileURL) == 0o600)
    #expect(try permissions(environment.trendDirectoryURL) == 0o700)
    #expect(environment.workingDirectories().isEmpty)

    let status = try environment.status()
    #expect(status["result"] as? String == "updated")
    #expect(status["words"] as? Int == 320)
    #expect(status["excluded"] as? Int == 0)
    #expect(status["months"] as? [String] == ["2026-08", "2026-09", "2026-10"])
    #expect(status["finishedAt"] as? String == "2026-11-23T12:00:00Z")
    #expect(status["error"] == nil)
    // 取得先は許可したホストだけ
    #expect(fetcher.requestedURLs.allSatisfy(TrendWordsDownloader.isAllowed))
    // 一時ファイルが残らない
    let names = try FileManager.default.contentsOfDirectory(atPath: environment.trendDirectoryURL.path)
    #expect(Set(names) == ["trend.tsv", "status.json"])
}

@Test func updateContinuesWithTwoMonths() async throws {
    let environment = try makeEnvironment()
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: makeFetcher(availableMonths: 2)))
    #expect(result.outcome == .updated)
    #expect(result.months == ["2026-09", "2026-10"])
}

@Test func singleMonthFailsAndKeepsOldList() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-7 * 24 * 60 * 60))
    let fetcher = makeFetcher(availableMonths: 1)
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher))
    #expect(result.outcome == .failed)
    #expect(environment.oldListIsIntact())
    #expect(environment.workingDirectories().isEmpty)
    // 読み辞書は取りに行かない
    #expect(!fetcher.requestedURLs.contains(TrendWordsDownloader.readingDictionaryURL))
    let status = try environment.status()
    #expect(status["result"] as? String == "failed")
    let error = try #require(status["error"] as? String)
    #expect(!error.contains("/"))
}

@Test func tooFewWordsFailsAndKeepsOldList() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-7 * 24 * 60 * 60))
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: makeFetcher(wordCount: 299)))
    #expect(result.outcome == .failed)
    #expect(result.words == 299)
    #expect(environment.oldListIsIntact())
    #expect(environment.workingDirectories().isEmpty)
}

@Test func missingReadingDictionaryFailsAndKeepsOldList() async throws {
    let environment = try makeEnvironment()
    try environment.writeOldList(modified: now.addingTimeInterval(-7 * 24 * 60 * 60))
    var responses: [URL: Data] = [:]
    for (year, month) in months {
        let url = TrendWordsDownloader.pageviewsURL(year: year, month: month)
        responses[url] = pageviewsJSON([("トレンド", 1)])
    }
    let result = await TrendWordsUpdate.run(options: environment.options(fetcher: FakeFetcher(responses: responses)))
    #expect(result.outcome == .failed)
    #expect(result.error == "reading dictionary: HTTP 404 (github.com)")
    #expect(environment.oldListIsIntact())
    #expect(environment.workingDirectories().isEmpty)
}

@Test func staleWorkingDirectoriesAreRemoved() async throws {
    let environment = try makeEnvironment()
    let stale = environment.trendDirectoryURL.appendingPathComponent("updating-stale", isDirectory: true)
    let recent = environment.trendDirectoryURL.appendingPathComponent("updating-recent", isDirectory: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 60 * 60)], ofItemAtPath: stale.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: recent.path)
    let fetcher = makeFetcher()
    _ = await TrendWordsUpdate.run(options: environment.options(fetcher: fetcher, enabled: false))
    // 古いものは消し、同時に走っている別の更新のもの（新しい）は残す
    #expect(environment.workingDirectories() == ["updating-recent"])
}
