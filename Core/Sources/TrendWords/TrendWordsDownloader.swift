import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 公開ファイルを取得してローカルのファイルに書く部分。テストでは差し替える
public protocol TrendWordsFetching: Sendable {
    /// `url` を GET し、本文を `destination` に書く。`maximumBytes` を超えたら失敗にする
    func download(_ url: URL, maximumBytes: Int64, to destination: URL) async throws
}

public enum TrendWordsDownloadError: Error, CustomStringConvertible, Equatable {
    case disallowedURL(host: String)
    case redirectRejected(host: String)
    case httpStatus(Int, host: String)
    case tooLarge(host: String)
    case network(code: Int, host: String)
    case localFile

    /// 短い説明。URL のクエリやローカルのパスは含めない
    public var description: String {
        switch self {
        case .disallowedURL(let host):
            "disallowed URL (\(host))"
        case .redirectRejected(let host):
            "redirect to a disallowed host (\(host))"
        case .httpStatus(let status, let host):
            "HTTP \(status) (\(host))"
        case .tooLarge(let host):
            "response too large (\(host))"
        case .network(let code, let host):
            "network error \(code) (\(host))"
        case .localFile:
            "could not write the downloaded file"
        }
    }
}

/// 流行語の一覧の材料を取得する
///
/// 利用者の情報は送らない。HTTPS の GET だけで、接続先は `allowedHosts` に限る。
/// Cookie・認証情報・キャッシュは使わず、User-Agent は固定の値にする。
public struct TrendWordsDownloader: TrendWordsFetching {
    public static let allowedHosts: Set<String> = [
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com",
        "wikimedia.org"
    ]
    public static let userAgent = "tenarai-TrendWords/1"
    public static let readingDictionaryURL = URL(string: "https://github.com/tokuhirom/jawiki-kana-kanji-dict/releases/latest/download/SKK-JISYO.jawiki")!
    public static let readingDictionaryMaximumBytes: Int64 = 80 * 1024 * 1024
    public static let pageviewsMaximumBytes: Int64 = 2 * 1024 * 1024
    static let requestTimeout: TimeInterval = 60
    static let resourceTimeout: TimeInterval = 10 * 60

    public init() {}

    /// 月別の閲覧上位（ja.wikipedia、全アクセス、全日）
    public static func pageviewsURL(year: Int, month: Int) -> URL {
        let monthText = month < 10 ? "0\(month)" : "\(month)"
        return URL(string: "https://wikimedia.org/api/rest_v1/metrics/pageviews/top/ja.wikipedia/all-access/\(year)/\(monthText)/all-days")!
    }

    /// `date` の前月から遡って `count` か月分（新しい順）。月の区切りは UTC
    public static func recentMonths(before date: Date, count: Int = 3) -> [(year: Int, month: Int)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: date)
        var year = components.year!
        var month = components.month!
        var result: [(year: Int, month: Int)] = []
        for _ in 0..<count {
            month -= 1
            if month == 0 {
                month = 12
                year -= 1
            }
            result.append((year, month))
        }
        return result
    }

    /// HTTPS で、許可したホストそのもの（部分一致や似た名前は不可）。ユーザー名・パスワード・443 以外のポートは不可
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.allowedHosts.contains(host),
              url.user == nil,
              url.password == nil else {
            return false
        }
        if let port = url.port, port != 443 {
            return false
        }
        return true
    }

    static func hostDescription(_ url: URL?) -> String {
        url?.host?.lowercased() ?? "unknown"
    }

    static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // 既定では利用者の言語設定が付くため、固定の値にする
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        return request
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "*"]
        return configuration
    }

    public func download(_ url: URL, maximumBytes: Int64, to destination: URL) async throws {
        guard Self.isAllowed(url) else {
            throw TrendWordsDownloadError.disallowedURL(host: Self.hostDescription(url))
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw TrendWordsDownloadError.localFile
        }
        defer { try? handle.close() }
        let transfer = Transfer(host: Self.hostDescription(url), maximumBytes: maximumBytes, handle: handle)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.makeConfiguration(), delegate: transfer, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            transfer.continuation = continuation
            session.dataTask(with: Self.makeRequest(url)).resume()
        }
    }
}

/// 1回の取得。デリゲートの呼び出しは直列のキューで行う
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let host: String
    let maximumBytes: Int64
    let handle: FileHandle
    var received: Int64 = 0
    var failure: TrendWordsDownloadError?
    var continuation: CheckedContinuation<Void, Error>?

    init(host: String, maximumBytes: Int64, handle: FileHandle) {
        self.host = host
        self.maximumBytes = maximumBytes
        self.handle = handle
    }

    private func fail(_ error: TrendWordsDownloadError) {
        if self.failure == nil {
            self.failure = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, TrendWordsDownloader.isAllowed(url) else {
            self.fail(.redirectRejected(host: TrendWordsDownloader.hostDescription(request.url)))
            completionHandler(nil)
            task.cancel()
            return
        }
        // 前のリクエストの見出しを引き継がず、同じ形の GET を作り直す
        completionHandler(TrendWordsDownloader.makeRequest(url))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // サーバー証明書の検証は既定のまま。認証情報は一切渡さない
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            self.fail(.network(code: 0, host: self.host))
            completionHandler(.cancel)
            return
        }
        guard let url = http.url, TrendWordsDownloader.isAllowed(url) else {
            self.fail(.redirectRejected(host: TrendWordsDownloader.hostDescription(http.url)))
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            self.fail(.httpStatus(http.statusCode, host: TrendWordsDownloader.hostDescription(url)))
            completionHandler(.cancel)
            return
        }
        if http.expectedContentLength > self.maximumBytes {
            self.fail(.tooLarge(host: self.host))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.failure == nil else {
            return
        }
        self.received += Int64(data.count)
        guard self.received <= self.maximumBytes else {
            self.fail(.tooLarge(host: self.host))
            dataTask.cancel()
            return
        }
        do {
            try self.handle.write(contentsOf: data)
        } catch {
            self.fail(.localFile)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: TrendWordsDownloadError?
        if let failure = self.failure {
            result = failure
        } else if let error {
            result = .network(code: (error as NSError).code, host: self.host)
        } else {
            result = nil
        }
        let continuation = self.continuation
        self.continuation = nil
        if let result {
            continuation?.resume(throwing: result)
        } else {
            continuation?.resume()
        }
    }
}
