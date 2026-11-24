import Foundation
import Testing
@testable import TrendWords

@Test func allowedHostsAreExactHTTPSHosts() throws {
    let allowed = [
        "https://github.com/tokuhirom/jawiki-kana-kanji-dict/releases/latest/download/SKK-JISYO.jawiki",
        "https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r",
        "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/2",
        "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/ja.wikipedia/all-access/2026/10/all-days",
        "https://GitHub.com/a",
        "https://github.com:443/a"
    ]
    for text in allowed {
        #expect(TrendWordsDownloader.isAllowed(try #require(URL(string: text))), "\(text)")
    }
    let rejected = [
        "http://github.com/a",
        "http://wikimedia.org/api/rest_v1/metrics/pageviews/top/ja.wikipedia/all-access/2026/10/all-days",
        "https://github.com.example.org/a",
        "https://evil-github.com/a",
        "https://example.com/a",
        "https://ja.wikipedia.org/wiki/a",
        "https://api.github.com/a",
        "https://user:pass@github.com/a",
        "https://github.com:8443/a",
        "ftp://github.com/a",
        "file:///etc/hosts"
    ]
    for text in rejected {
        #expect(!TrendWordsDownloader.isAllowed(try #require(URL(string: text))), "\(text)")
    }
}

@Test func sourceURLsAreAllowed() {
    #expect(TrendWordsDownloader.isAllowed(TrendWordsDownloader.readingDictionaryURL))
    #expect(TrendWordsDownloader.isAllowed(TrendWordsDownloader.pageviewsURL(year: 2026, month: 1)))
}

@Test func pageviewsURLUsesTwoDigitMonth() {
    #expect(TrendWordsDownloader.pageviewsURL(year: 2026, month: 3).absoluteString
        == "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/ja.wikipedia/all-access/2026/03/all-days")
    #expect(TrendWordsDownloader.pageviewsURL(year: 2025, month: 12).absoluteString
        == "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/ja.wikipedia/all-access/2025/12/all-days")
}

private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 3))!
}

@Test func recentMonthsCrossYearBoundary() {
    #expect(TrendWordsDownloader.recentMonths(before: utcDate(2027, 1, 4)).map { [$0.year, $0.month] }
        == [[2026, 12], [2026, 11], [2026, 10]])
    #expect(TrendWordsDownloader.recentMonths(before: utcDate(2027, 2, 1)).map { [$0.year, $0.month] }
        == [[2027, 1], [2026, 12], [2026, 11]])
    #expect(TrendWordsDownloader.recentMonths(before: utcDate(2026, 11, 23)).map { [$0.year, $0.month] }
        == [[2026, 10], [2026, 9], [2026, 8]])
}

@Test func requestsCarryOnlyFixedHeaders() throws {
    let request = TrendWordsDownloader.makeRequest(TrendWordsDownloader.readingDictionaryURL)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.allHTTPHeaderFields == ["User-Agent": "tenarai-TrendWords/1", "Accept-Language": "*"])

    let configuration = TrendWordsDownloader.makeConfiguration()
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.timeoutIntervalForRequest == 60)
    #expect(configuration.timeoutIntervalForResource == 600)
}

@Test func disallowedURLIsRejectedBeforeAnyConnection() async throws {
    let directoryURL = try makeTemporaryDirectoryURL()
    let destination = directoryURL.appendingPathComponent("file")
    await #expect(throws: TrendWordsDownloadError.disallowedURL(host: "example.com")) {
        try await TrendWordsDownloader().download(URL(string: "https://example.com/a")!, maximumBytes: 10, to: destination)
    }
    await #expect(throws: TrendWordsDownloadError.disallowedURL(host: "github.com")) {
        try await TrendWordsDownloader().download(URL(string: "http://github.com/a")!, maximumBytes: 10, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
