import Foundation

/// 流行語の一覧（読み<TAB>表記<TAB>閲覧数<TAB>月数）を作る。
///
/// `Tools/trend_words/build_list.py` の移植。取得済みのファイルだけを読み、通信しない。
/// 文字列の比較・長さは Python と同じくコードポイント単位で行う（Swift の `String` の
/// 正準等価による比較は使わない）。
public enum TrendWordListBuilder {
    public struct Row: Equatable, Sendable {
        public var reading: String
        public var word: String
        public var views: Int
        public var months: Int

        public init(reading: String, word: String, views: Int, months: Int) {
            self.reading = reading
            self.word = word
            self.views = views
            self.months = months
        }
    }

    /// 基本辞書の一般的な語と読みが重なるため除外した行
    public struct ExcludedRow: Equatable, Sendable {
        public var row: Row
        public var rivalWord: String
        public var rivalValue: Float
    }

    public struct Output: Sendable {
        public var kept: [Row]
        public var excluded: [ExcludedRow]
        /// 閲覧上位に現れた記事の数（題名の整形後）
        public var articleCount: Int
        /// その他の除外の内訳（理由 → 件数）
        public var skipped: [String: Int]
    }

    public enum BuildError: Error, CustomStringConvertible {
        case unreadableReadingDictionary
        case invalidPageviews(String)
        case unreadableBaseDictionary

        public var description: String {
            switch self {
            case .unreadableReadingDictionary:
                "reading dictionary could not be read"
            case .invalidPageviews(let name):
                "pageviews file is invalid: \(name)"
            case .unreadableBaseDictionary:
                "base dictionary could not be read"
            }
        }
    }

    /// 基本辞書でこれ以上のコストを持つ別の語があれば、一般的な語とみなす
    public static let commonValue: Double = -13.0
    public static let maximumWords = 5_000
    static let titleLengthRange = 2...14
    static let minimumReadingLength = 3
    static let eventPatterns = ["事件", "事故", "一覧", "年の", "選挙", "戦争", "震災"].map { Array($0.utf8) }

    enum SkipReason: String {
        case unknownReading = "読みが分からない"
        case length = "長さ"
        case hiraganaOnly = "ひらがなだけ"
        case event = "出来事など"
        case shortReading = "読みが短い"
    }

    // MARK: - 全体

    /// - Parameters:
    ///   - readingDictionaryURL: `SKK-JISYO.jawiki`
    ///   - pageviewURLs: 月ごとの閲覧上位 JSON。ファイル名順に処理する
    ///   - loudsDirectoryURL: 基本辞書の `louds` ディレクトリ
    public static func build(readingDictionaryURL: URL, pageviewURLs: [URL], loudsDirectoryURL: URL) throws -> Output {
        // 1. 閲覧上位を集める（初めて現れた順を保つ）
        var order: [[UInt8]] = []
        var titles: [[UInt8]: String] = [:]
        var views: [[UInt8]: Int] = [:]
        var months: [[UInt8]: Int] = [:]
        let sortedURLs = pageviewURLs.sorted { Array($0.lastPathComponent.unicodeScalars.map(\.value)).lexicographicallyPrecedes($1.lastPathComponent.unicodeScalars.map(\.value)) }
        for url in sortedURLs {
            for article in try Self.loadPageviews(from: url) {
                let title = article.title
                if title.unicodeScalars.contains(":") || title.utf8.elementsEqual("メインページ".utf8) {
                    continue
                }
                let normalized = Self.normalizeTitle(title)
                let key = Array(normalized.utf8)
                if views[key] == nil {
                    order.append(key)
                    titles[key] = normalized
                    views[key] = 0
                    months[key] = 0
                }
                views[key]! += article.views
                months[key]! += 1
            }
        }

        // 2. 必要な題名の読みだけを辞書から拾う
        let readings = try Self.readings(for: Set(order), readingDictionaryURL: readingDictionaryURL)

        // 3. 閲覧数の降順（同数は最初に現れた順。安定ソート）
        let ranked = order.enumerated()
            .sorted { lhs, rhs in
                let left = views[lhs.element]!
                let right = views[rhs.element]!
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)

        var skipped: [String: Int] = [:]
        var rows: [Row] = []
        for key in ranked {
            let title = titles[key]!
            let titleLength = title.unicodeScalars.count
            let reason: SkipReason?
            if readings[key] == nil {
                reason = .unknownReading
            } else if !Self.titleLengthRange.contains(titleLength) {
                reason = .length
            } else if Self.isHiraganaOnly(title) {
                reason = .hiraganaOnly
            } else if Self.isEvent(key) || title.unicodeScalars.contains(where: Self.isOtherCategory) {
                reason = .event
            } else if readings[key]!.unicodeScalars.count < Self.minimumReadingLength {
                reason = .shortReading
            } else {
                reason = nil
            }
            if let reason {
                skipped[reason.rawValue, default: 0] += 1
            } else {
                rows.append(Row(reading: readings[key]!, word: title, views: views[key]!, months: months[key]!))
            }
        }

        // 4. 基本辞書の一般的な語と読みが重なるものを除く
        let rubies = Set(rows.map { Array(Self.katakana($0.reading).utf8) })
        let base = try Self.baseEntries(loudsDirectoryURL: loudsDirectoryURL, rubies: rubies)
        var kept: [Row] = []
        var excluded: [ExcludedRow] = []
        for row in rows {
            let key = Self.spellingKey(row.word)
            var rival: (word: String, value: Float)?
            for entry in base[Array(Self.katakana(row.reading).utf8)] ?? [] {
                guard Double(entry.value) >= Self.commonValue, Self.spellingKey(entry.word) != key else {
                    continue
                }
                // 最大値のうち最初のもの（Python の max と同じ）
                if rival == nil || entry.value > rival!.value {
                    rival = entry
                }
            }
            if let rival {
                excluded.append(ExcludedRow(row: row, rivalWord: rival.word, rivalValue: rival.value))
            } else {
                kept.append(row)
            }
        }
        kept = Array(kept.prefix(Self.maximumWords))
        return Output(kept: kept, excluded: excluded, articleCount: order.count, skipped: skipped)
    }

    // MARK: - 書き出し

    public static func tsv(_ rows: [Row]) -> String {
        rows.map { "\($0.reading)\t\($0.word)\t\($0.views)\t\($0.months)\n" }.joined()
    }

    public static func excludedTSV(_ rows: [ExcludedRow]) -> String {
        rows.map {
            "\($0.row.reading)\t\($0.row.word)\t\($0.row.views)\t\($0.row.months)\t\($0.rivalWord)\t"
                + String(format: "%.2f", Double($0.rivalValue)) + "\n"
        }.joined()
    }

    // MARK: - 閲覧上位

    public struct Article: Equatable, Sendable {
        public var title: String
        public var views: Int
    }

    private struct PageviewsFile: Decodable {
        struct Item: Decodable {
            struct Entry: Decodable {
                var article: String
                var views: Int
            }
            var articles: [Entry]
        }
        var items: [Item]
    }

    /// Wikimedia の月別閲覧上位 JSON を読む（`items[0].articles`）
    public static func loadPageviews(from url: URL) throws -> [Article] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PageviewsFile.self, from: data),
              let first = file.items.first else {
            throw BuildError.invalidPageviews(url.lastPathComponent)
        }
        return first.articles.map { Article(title: $0.article, views: $0.views) }
    }

    /// 末尾の `_(…)` を外し、`_` を空白にする（Python の `re.sub(r'_\(.*\)$', '', t).replace('_', ' ')`）
    static func normalizeTitle(_ title: String) -> String {
        var scalars = Array(title.unicodeScalars)
        if scalars.last == ")" {
            // 最も左の `_(` で、その後ろに閉じ括弧が置ける位置
            var index = 0
            while index + 2 < scalars.count {
                if scalars[index] == "_", scalars[index + 1] == "(" {
                    scalars.removeSubrange(index...)
                    break
                }
                index += 1
            }
        }
        var result = String.UnicodeScalarView()
        for scalar in scalars {
            result.append(scalar == "_" ? " " : scalar)
        }
        return String(result)
    }

    // MARK: - 読み辞書

    /// SKK 形式の読み辞書を1行ずつ見て、`titles`（UTF-8 のバイト列）の最初の読みだけを残す
    static func readings(for titles: Set<[UInt8]>, readingDictionaryURL: URL) throws -> [[UInt8]: String] {
        guard let handle = try? FileHandle(forReadingFrom: readingDictionaryURL) else {
            throw BuildError.unreadableReadingDictionary
        }
        defer { try? handle.close() }
        var result: [[UInt8]: String] = [:]
        var pending: [UInt8] = []
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                throw BuildError.unreadableReadingDictionary
            }
            if chunk.isEmpty {
                break
            }
            pending.append(contentsOf: chunk)
            var lineStart = 0
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                Self.readLine(pending[lineStart..<newline], titles: titles, into: &result)
                lineStart = newline + 1
            }
            pending.removeFirst(lineStart)
        }
        if !pending.isEmpty {
            Self.readLine(pending[...], titles: titles, into: &result)
        }
        return result
    }

    private static let slash: UInt8 = 0x2F
    private static let space: UInt8 = 0x20
    private static let semicolon: UInt8 = 0x3B

    private static func readLine(_ rawLine: ArraySlice<UInt8>, titles: Set<[UInt8]>, into result: inout [[UInt8]: String]) {
        // Python はテキストモード（改行の変換あり）で読む。\r\n と \r は \n とみなす
        var line = rawLine
        if line.last == 0x0D {
            line = line.dropLast()
        }
        guard line.first != semicolon else {
            return
        }
        // 最初の " /" で読みと残りに分ける
        var separator: Int?
        var index = line.startIndex
        while index + 1 < line.endIndex {
            if line[index] == space, line[index + 1] == slash {
                separator = index
                break
            }
            index += 1
        }
        guard let separator else {
            return
        }
        let readingBytes = line[line.startIndex..<separator]
        var reading: String?
        var start = separator + 2
        while start <= line.endIndex {
            let end = line[start...].firstIndex(of: slash) ?? line.endIndex
            var word = line[start..<end]
            if let annotation = word.firstIndex(of: semicolon) {
                word = word[word.startIndex..<annotation]
            }
            if !word.isEmpty {
                let key = Array(word)
                if result[key] == nil, titles.contains(key) {
                    if reading == nil {
                        guard let decoded = String(bytes: readingBytes, encoding: .utf8),
                              Self.isHiraganaOnly(decoded) else {
                            return
                        }
                        reading = decoded
                    }
                    result[key] = reading
                }
            }
            start = end + 1
        }
    }

    // MARK: - 基本辞書

    /// `rubies`（カタカナの読み、UTF-8）に一致する基本辞書の語とコストを集める
    static func baseEntries(loudsDirectoryURL: URL, rubies: Set<[UInt8]>) throws -> [[UInt8]: [(word: String, value: Float)]] {
        guard !rubies.isEmpty else {
            return [:]
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: loudsDirectoryURL.path) else {
            throw BuildError.unreadableBaseDictionary
        }
        let firsts = Set(rubies.compactMap { String(decoding: $0, as: UTF8.self).unicodeScalars.first?.value }).sorted()
        var found: [[UInt8]: [(word: String, value: Float)]] = [:]
        for first in firsts {
            let prefix = "[" + String(format: "%04X", first) + "]"
            let shards = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".loudstxt3") }.sorted()
            for name in shards {
                guard let data = try? Data(contentsOf: loudsDirectoryURL.appendingPathComponent(name, isDirectory: false)) else {
                    throw BuildError.unreadableBaseDictionary
                }
                try Self.readShard([UInt8](data)) { ruby, word, value in
                    if rubies.contains(ruby) {
                        found[ruby, default: []].append((word, value))
                    }
                }
            }
        }
        return found
    }

    /// `.loudstxt3` を読む。各語について（読み、表記、コスト）を渡す
    static func readShard(_ data: [UInt8], _ body: ([UInt8], String, Float) -> Void) throws {
        func uint16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else {
                throw BuildError.unreadableBaseDictionary
            }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func uint32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= data.count else {
                throw BuildError.unreadableBaseDictionary
            }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        let count = try uint16(0)
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        for i in 0..<count {
            offsets.append(Int(try uint32(2 + 4 * i)))
        }
        for i in 0..<count {
            let start = offsets[i]
            let end = i + 1 < count ? offsets[i + 1] : data.count
            let n = try uint16(start)
            let textStart = start + 2 + 10 * n
            guard textStart <= end, end <= data.count else {
                throw BuildError.unreadableBaseDictionary
            }
            let textBytes = data[textStart..<end]
            // 読み（最初の列）を先に比べ、関係のない項目は文字列にしない
            let rubyEnd = textBytes.firstIndex(of: 0x09) ?? end
            let ruby = Array(String(decoding: textBytes[textStart..<rubyEnd], as: UTF8.self).utf8)
            var texts: [String]?
            for k in 0..<n {
                let valueBits = try uint32(start + 2 + 10 * k + 6)
                let value = Float(bitPattern: valueBits)
                if texts == nil {
                    texts = String(decoding: textBytes, as: UTF8.self)
                        .split(separator: "\t", omittingEmptySubsequences: false)
                        .map(String.init)
                }
                let texts = texts!
                let word = k + 1 < texts.count && !texts[k + 1].isEmpty ? texts[k + 1] : texts[0]
                body(ruby, word, value)
            }
        }
    }

    // MARK: - 文字の判定

    /// ひらがなをカタカナにする（ぁ〜ゖ だけ。長音などはそのまま）
    static func katakana(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if (0x3041...0x3096).contains(scalar.value), let shifted = Unicode.Scalar(scalar.value + 0x60) {
                result.append(shifted)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// `[ぁ-ゖー]+` に全体が一致する
    static func isHiraganaOnly(_ text: String) -> Bool {
        !text.unicodeScalars.isEmpty && text.unicodeScalars.allSatisfy {
            (0x3041...0x3096).contains($0.value) || $0.value == 0x30FC
        }
    }

    private static func isEvent(_ utf8: [UInt8]) -> Bool {
        Self.eventPatterns.contains { pattern in
            guard utf8.count >= pattern.count else {
                return false
            }
            for start in 0...(utf8.count - pattern.count) where utf8[start..<(start + pattern.count)].elementsEqual(pattern) {
                return true
            }
            return false
        }
    }

    /// Unicode の一般カテゴリが C（Cc, Cf, Cs, Co, Cn）
    static func isOtherCategory(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            true
        default:
            false
        }
    }

    /// 空白・大文字小文字・記号の違いだけの同じ名前は同じ値になる
    /// （Python の NFKC + casefold + `isalnum` の文字だけ）
    static func spellingKey(_ word: String) -> [UInt8] {
        let folded = word.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
        var result: [UInt8] = []
        for scalar in folded.unicodeScalars where Self.isAlphanumeric(scalar) {
            result.append(contentsOf: String(scalar).utf8)
        }
        return result
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return scalar.properties.numericType != nil
        }
    }
}
