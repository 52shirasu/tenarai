import Foundation

/// 外部で作った流行語の一覧（`trend/trend.tsv`）を読む。
///
/// 一覧はユーザー辞書と一緒にコンパイル済み辞書へ合流させる。このファイルは読むだけで、
/// 取得や生成はしない。
public enum TrendWordsStore {
    public struct Entry: Equatable, Hashable, Sendable {
        public var reading: String
        public var word: String

        public init(reading: String, word: String) {
            self.reading = reading
            self.word = word
        }
    }

    /// これより大きいファイルは読まない
    static let maximumFileSize = 2 * 1024 * 1024
    /// 先頭から読む最大件数
    static let maximumEntries = 5_000
    static let readingLengthRange = 3...30
    static let wordLengthRange = 2...30

    public static func fileURL(applicationSupportDirectoryURL: URL) -> URL {
        applicationSupportDirectoryURL
            .appendingPathComponent("trend", isDirectory: true)
            .appendingPathComponent("trend.tsv", isDirectory: false)
    }

    /// 一覧を読む。ファイルがない・大きすぎる・読めないときは空を返す
    public static func load(from url: URL) -> [Entry] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= Self.maximumFileSize,
              let data = try? Data(contentsOf: url),
              data.count <= Self.maximumFileSize,
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        return Self.parse(content)
    }

    static func parse(_ content: String) -> [Entry] {
        var seen: Set<Entry> = []
        var entries: [Entry] = []
        for line in content.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 2 else {
                continue
            }
            let entry = Entry(reading: String(columns[0]), word: String(columns[1]))
            guard Self.isValid(entry), seen.insert(entry).inserted else {
                continue
            }
            entries.append(entry)
            if entries.count >= Self.maximumEntries {
                break
            }
        }
        return entries
    }

    static func isValid(_ entry: Entry) -> Bool {
        guard Self.readingLengthRange.contains(entry.reading.count),
              entry.reading.unicodeScalars.allSatisfy(Self.isReadingScalar) else {
            return false
        }
        guard Self.wordLengthRange.contains(entry.word.count),
              entry.word != entry.reading,
              !entry.word.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !entry.word.contains(where: \.isNewline) else {
            return false
        }
        return true
    }

    private static func isReadingScalar(_ scalar: Unicode.Scalar) -> Bool {
        // ぁ(U+3041)〜ゖ(U+3096) と長音「ー」(U+30FC)
        (0x3041...0x3096).contains(scalar.value) || scalar.value == 0x30FC
    }

    /// 書き出した辞書がどの一覧から作られたかを表す文字列
    ///
    /// 設定がオフなら `"off"`、ファイルがなければ `"none"`、あれば `"<サイズ>-<更新時刻の秒>"`
    public static func stamp(for url: URL, enabled: Bool) -> String {
        guard enabled else {
            return "off"
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return "none"
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) } ?? 0
        return "\(size)-\(modified)"
    }
}
