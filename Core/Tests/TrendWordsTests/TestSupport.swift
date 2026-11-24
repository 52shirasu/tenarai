import Foundation
@testable import TrendWords

/// テスト用の一時ディレクトリ（`$TMPDIR` の下）
func makeTemporaryDirectoryURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TrendWordsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 閲覧上位 JSON（Wikimedia の形）
func pageviewsJSON(_ articles: [(String, Int)]) -> Data {
    let items: [[String: Any]] = [[
        "project": "ja.wikipedia",
        "access": "all-access",
        "articles": articles.enumerated().map { ["article": $0.element.0, "views": $0.element.1, "rank": $0.offset + 1] }
    ]]
    return try! JSONSerialization.data(withJSONObject: ["items": items])
}

/// `.loudstxt3` のバイト列を組み立てる
///
/// 形式: 項目数(UInt16) + 各項目の位置(UInt32) + 項目（語数(UInt16) + 語ごとの 10 バイト（UInt16×3 + Float32）
/// + 「読み<TAB>表記<TAB>…」）。すべてリトルエンディアン
func makeShard(_ entries: [(ruby: String, words: [(word: String, value: Float)])]) -> Data {
    var bodies: [[UInt8]] = []
    for entry in entries {
        var body: [UInt8] = []
        appendUInt16(&body, entry.words.count)
        for word in entry.words {
            appendUInt16(&body, 0)
            appendUInt16(&body, 0)
            appendUInt16(&body, 0)
            let bits = word.value.bitPattern
            body += [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24 & 0xFF)]
        }
        body += Array(([entry.ruby] + entry.words.map(\.word)).joined(separator: "\t").utf8)
        bodies.append(body)
    }
    var data: [UInt8] = []
    appendUInt16(&data, entries.count)
    var offset = 2 + 4 * entries.count
    for body in bodies {
        data += [UInt8(offset & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 24 & 0xFF)]
        offset += body.count
    }
    for body in bodies {
        data += body
    }
    return Data(data)
}

private func appendUInt16(_ data: inout [UInt8], _ value: Int) {
    data += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
}

/// 取得の差し替え。通信せず、用意したデータを書く
final class FakeFetcher: TrendWordsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data]
    private var calls: [URL] = []

    init(responses: [URL: Data]) {
        self.responses = responses
    }

    var requestedURLs: [URL] {
        self.lock.withLock { self.calls }
    }

    func download(_ url: URL, maximumBytes: Int64, to destination: URL) async throws {
        let data: Data? = self.lock.withLock {
            self.calls.append(url)
            return self.responses[url]
        }
        guard let data else {
            throw TrendWordsDownloadError.httpStatus(404, host: url.host ?? "unknown")
        }
        guard Int64(data.count) <= maximumBytes else {
            throw TrendWordsDownloadError.tooLarge(host: url.host ?? "unknown")
        }
        try data.write(to: destination)
    }
}
