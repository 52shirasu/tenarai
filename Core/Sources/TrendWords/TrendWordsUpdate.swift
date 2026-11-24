import Foundation

/// 流行語の一覧を取得して作り直す全体の流れ
///
/// 失敗しても既存の `trend.tsv` は壊さない・消さない。
public enum TrendWordsUpdate {
    public struct Options: Sendable {
        /// 鮮度の確認を飛ばす
        public var force: Bool
        /// 基本辞書の `louds` ディレクトリ
        public var loudsDirectoryURL: URL
        /// データの場所（`trend/` の親）
        public var applicationSupportDirectoryURL: URL
        public var isEnabled: @Sendable () -> Bool
        public var fetcher: any TrendWordsFetching
        public var now: @Sendable () -> Date

        public init(
            force: Bool,
            loudsDirectoryURL: URL,
            applicationSupportDirectoryURL: URL = TrendWordsLocations.applicationSupportDirectoryURL(),
            isEnabled: @escaping @Sendable () -> Bool = { TrendWordsLocations.isEnabled() },
            fetcher: any TrendWordsFetching = TrendWordsDownloader(),
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.force = force
            self.loudsDirectoryURL = loudsDirectoryURL
            self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
            self.isEnabled = isEnabled
            self.fetcher = fetcher
            self.now = now
        }
    }

    public enum Outcome: String, Sendable, Codable {
        case updated
        case skippedDisabled = "skipped-disabled"
        case skippedFresh = "skipped-fresh"
        case failed
    }

    public struct Result: Sendable, Equatable {
        public var outcome: Outcome
        public var words: Int
        public var excluded: Int
        /// 使えた月（`YYYY-MM`、古い順）
        public var months: [String]
        /// 失敗時の短い説明（URL のクエリやローカルのパスを含めない）
        public var error: String?

        public init(outcome: Outcome, words: Int = 0, excluded: Int = 0, months: [String] = [], error: String? = nil) {
            self.outcome = outcome
            self.words = words
            self.excluded = excluded
            self.months = months
            self.error = error
        }

        /// 標準出力とログに出す1行（語の中身は含めない）
        public var summary: String {
            var parts = [self.outcome.rawValue, "words=\(self.words)", "excluded=\(self.excluded)"]
            if !self.months.isEmpty {
                parts.append("months=" + self.months.joined(separator: ","))
            }
            if let error = self.error {
                parts.append("error=" + error)
            }
            return parts.joined(separator: " ")
        }
    }

    /// `trend.tsv` がこれより新しければ取得しない
    public static let freshInterval: TimeInterval = 6 * 24 * 60 * 60
    /// 採用がこれ未満なら異常とみなす
    public static let minimumWords = 300
    /// 使える月がこれ未満なら失敗
    public static let minimumMonths = 2
    static let monthCount = 3
    static let workingDirectoryPrefix = "updating-"
    /// これより古い作業用ディレクトリは前回の残りとみなして消す（同時に走っている別の更新のものは消さない）
    static let staleWorkingDirectoryAge: TimeInterval = 60 * 60
    static let readingDictionaryFileName = "SKK-JISYO.jawiki"

    struct Failure: Error {
        var message: String
        var words = 0
        var excluded = 0
        var months: [String] = []
    }

    public static func run(options: Options) async -> Result {
        let fileManager = FileManager.default
        let trendDirectoryURL = TrendWordsLocations.trendDirectoryURL(applicationSupportDirectoryURL: options.applicationSupportDirectoryURL)
        let trendFileURL = TrendWordsLocations.trendFileURL(applicationSupportDirectoryURL: options.applicationSupportDirectoryURL)
        Self.removeStaleWorkingDirectories(in: trendDirectoryURL, now: options.now())

        let result: Result
        if !options.isEnabled() {
            result = Result(outcome: .skippedDisabled)
        } else if !options.force, Self.isFresh(trendFileURL, now: options.now()) {
            result = Result(outcome: .skippedFresh)
        } else {
            do {
                result = try await Self.update(options: options, trendDirectoryURL: trendDirectoryURL, trendFileURL: trendFileURL, fileManager: fileManager)
            } catch let failure as Failure {
                result = Result(outcome: .failed, words: failure.words, excluded: failure.excluded, months: failure.months, error: failure.message)
            } catch {
                result = Result(outcome: .failed, error: "unexpected error")
            }
        }
        Self.writeStatus(result, trendDirectoryURL: trendDirectoryURL, now: options.now())
        return result
    }

    static func isFresh(_ trendFileURL: URL, now: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: trendFileURL.path),
              let modified = attributes[.modificationDate] as? Date else {
            return false
        }
        let age = now.timeIntervalSince(modified)
        return age >= 0 && age < Self.freshInterval
    }

    private static func update(options: Options, trendDirectoryURL: URL, trendFileURL: URL, fileManager: FileManager) async throws -> Result {
        try Self.prepareTrendDirectory(trendDirectoryURL)
        let workingDirectoryURL = trendDirectoryURL.appendingPathComponent(Self.workingDirectoryPrefix + UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure(message: "could not create the working directory")
        }
        defer { try? fileManager.removeItem(at: workingDirectoryURL) }

        // 閲覧上位（小さいので先に取る。月初は前月分がまだ無いことがある）
        var pageviewURLs: [URL] = []
        var months: [String] = []
        var lastError: String?
        for (year, month) in TrendWordsDownloader.recentMonths(before: options.now(), count: Self.monthCount).reversed() {
            let name = String(format: "%04d-%02d", year, month)
            let destination = workingDirectoryURL.appendingPathComponent("top-\(name).json", isDirectory: false)
            do {
                try await options.fetcher.download(
                    TrendWordsDownloader.pageviewsURL(year: year, month: month),
                    maximumBytes: TrendWordsDownloader.pageviewsMaximumBytes,
                    to: destination
                )
                _ = try TrendWordListBuilder.loadPageviews(from: destination)
                pageviewURLs.append(destination)
                months.append(name)
            } catch {
                try? fileManager.removeItem(at: destination)
                lastError = Self.describe(error)
            }
        }
        guard months.count >= Self.minimumMonths else {
            throw Failure(message: "pageviews available for \(months.count) month(s)" + (lastError.map { ": " + $0 } ?? ""), months: months)
        }

        let dictionaryURL = workingDirectoryURL.appendingPathComponent(Self.readingDictionaryFileName, isDirectory: false)
        do {
            try await options.fetcher.download(
                TrendWordsDownloader.readingDictionaryURL,
                maximumBytes: TrendWordsDownloader.readingDictionaryMaximumBytes,
                to: dictionaryURL
            )
        } catch {
            throw Failure(message: "reading dictionary: " + Self.describe(error), months: months)
        }

        let output: TrendWordListBuilder.Output
        do {
            output = try TrendWordListBuilder.build(
                readingDictionaryURL: dictionaryURL,
                pageviewURLs: pageviewURLs,
                loudsDirectoryURL: options.loudsDirectoryURL
            )
        } catch {
            throw Failure(message: Self.describe(error), months: months)
        }
        guard output.kept.count >= Self.minimumWords else {
            throw Failure(
                message: "too few words (\(output.kept.count))",
                words: output.kept.count,
                excluded: output.excluded.count,
                months: months
            )
        }
        do {
            try Self.writeAtomically(Data(TrendWordListBuilder.tsv(output.kept).utf8), to: trendFileURL)
        } catch {
            throw Failure(message: "could not write the list", words: output.kept.count, excluded: output.excluded.count, months: months)
        }
        return Result(outcome: .updated, words: output.kept.count, excluded: output.excluded.count, months: months)
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? TrendWordsDownloadError {
            return error.description
        }
        if let error = error as? TrendWordListBuilder.BuildError {
            return error.description
        }
        return "error"
    }

    /// `trend/` を作り、権限を 700 にする
    static func prepareTrendDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw Failure(message: "could not prepare the trend directory")
        }
    }

    /// 前回の残りの `updating-*` を消す
    static func removeStaleWorkingDirectories(in trendDirectoryURL: URL, now: Date) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: trendDirectoryURL.path) else {
            return
        }
        for name in names where name.hasPrefix(Self.workingDirectoryPrefix) {
            let url = trendDirectoryURL.appendingPathComponent(name, isDirectory: true)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else {
                continue
            }
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) >= Self.staleWorkingDirectoryAge {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 同じディレクトリに一時ファイルを書いて rename で置き換える。権限は 600
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "could not write a file")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw Failure(message: "could not replace a file")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private struct Status: Encodable {
        var finishedAt: String
        var result: String
        var words: Int
        var excluded: Int
        var months: [String]
        var error: String?
    }

    /// `trend/status.json` に結果を書く（権限 600）。書けなくても結果は変えない
    static func writeStatus(_ result: Result, trendDirectoryURL: URL, now: Date) {
        let status = Status(
            finishedAt: ISO8601DateFormatter().string(from: now),
            result: result.outcome.rawValue,
            words: result.words,
            excluded: result.excluded,
            months: result.months,
            error: result.error
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(status) else {
            return
        }
        do {
            try Self.prepareTrendDirectory(trendDirectoryURL)
            try Self.writeAtomically(
                data + Data("\n".utf8),
                to: trendDirectoryURL.appendingPathComponent("status.json", isDirectory: false)
            )
        } catch {
            // 状態の記録に失敗しても一覧には影響しない
        }
    }
}
