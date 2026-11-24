import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public enum CompiledUserDictionaryStore {
    enum BuildError: Error {
        case missingCharIDFile
    }

    public static func directoryURL(memoryDirectoryURL: URL) -> URL {
        memoryDirectoryURL.appendingPathComponent("UserDictionary", isDirectory: true)
    }

    /// 書き出した辞書がどの流行語一覧から作られたかを記録するファイル
    static let trendStampFileName = "trend.stamp"

    public static func exportCurrentDictionaries(memoryDirectoryURL: URL) throws {
        try Self.export(
            memoryDirectoryURL: memoryDirectoryURL,
            personal: Self.currentEntries(),
            trendFileURL: Self.currentTrendFileURL(),
            trendEnabled: Config.TrendWords().value
        )
    }

    /// 設定を読まずに書き出す部分。テストから直接呼ぶ
    static func export(
        memoryDirectoryURL: URL,
        personal: [DicdataElement],
        trendFileURL: URL,
        trendEnabled: Bool,
        charIDFileURL: URL? = nil
    ) throws {
        // 先に stamp を取る。読み込み中に一覧が書き換わっても、次回の needsExport で拾える
        let stamp = TrendWordsStore.stamp(for: trendFileURL, enabled: trendEnabled)
        let trend = trendEnabled ? TrendWordsStore.load(from: trendFileURL) : []
        try Self.rebuild(
            entries: Self.mergedEntries(personal: personal, trend: trend),
            directoryURL: Self.directoryURL(memoryDirectoryURL: memoryDirectoryURL),
            charIDFileURL: charIDFileURL,
            trendStamp: stamp
        )
    }

    public static func hasExportedDictionary(memoryDirectoryURL: URL) -> Bool {
        Self.hasCompiledDictionary(at: Self.directoryURL(memoryDirectoryURL: memoryDirectoryURL))
    }

    /// 書き出しが必要か。書き出し時の `trend.stamp` がない、または現在の一覧・設定と違うとき true
    public static func needsExport(memoryDirectoryURL: URL) -> Bool {
        Self.needsExport(
            memoryDirectoryURL: memoryDirectoryURL,
            trendFileURL: Self.currentTrendFileURL(),
            trendEnabled: Config.TrendWords().value
        )
    }

    static func needsExport(memoryDirectoryURL: URL, trendFileURL: URL, trendEnabled: Bool) -> Bool {
        let directoryURL = Self.directoryURL(memoryDirectoryURL: memoryDirectoryURL)
        let stampURL = directoryURL.appendingPathComponent(Self.trendStampFileName, isDirectory: false)
        // stamp は書き出しのたびに書くので、stamp がなければ未書き出し（または旧版の書き出し）とみなす。
        // 辞書が空のときはコンパイル済みファイルができないが、stamp が一致していれば書き出さない
        guard let exportedStamp = try? String(contentsOf: stampURL, encoding: .utf8) else {
            return true
        }
        return exportedStamp != TrendWordsStore.stamp(for: trendFileURL, enabled: trendEnabled)
    }

    private static func currentTrendFileURL() -> URL {
        TrendWordsStore.fileURL(applicationSupportDirectoryURL: AppGroup.applicationSupportDirectoryURL())
    }

    private static func currentEntries() -> [DicdataElement] {
        let userEntries = Config.UserDictionary().value.items.map { item in
            Self.makeElement(word: item.word, reading: item.reading)
        }
        let systemEntries = Config.SystemUserDictionary().value.items.map { item in
            Self.makeElement(word: item.word, reading: item.reading)
        }
        return userEntries + systemEntries
    }

    private static func makeElement(word: String, reading: String) -> DicdataElement {
        DicdataElement(word: word, ruby: reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
    }

    /// 本人の辞書に流行語を足す。本人の辞書に同じ読みの語が1つでもある流行語は入れない
    static func mergedEntries(personal: [DicdataElement], trend: [TrendWordsStore.Entry]) -> [DicdataElement] {
        let personalRubies = Set(personal.map(\.ruby))
        let trendEntries = trend
            .map { Self.makeElement(word: $0.word, reading: $0.reading) }
            .filter { !personalRubies.contains($0.ruby) }
        return personal + trendEntries
    }

    static func hasCompiledDictionary(at directoryURL: URL) -> Bool {
        ["user.louds", "user.loudschars2", "user0.loudstxt3"].allSatisfy {
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0, isDirectory: false).path)
        }
    }

    static func rebuild(
        entries: [DicdataElement],
        directoryURL: URL,
        charIDFileURL: URL? = nil,
        trendStamp: String? = nil
    ) throws {
        let fileManager = FileManager.default
        let parentURL = directoryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)

        let temporaryURL = parentURL.appendingPathComponent(
            "\(directoryURL.lastPathComponent).building-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            if !entries.isEmpty {
                guard let charIDFileURL = charIDFileURL ?? Self.defaultCharIDFileURL() else {
                    throw BuildError.missingCharIDFile
                }
                let supportedCharacters = Set(try String(contentsOf: charIDFileURL, encoding: .utf8))
                let indexableEntries = entries.filter {
                    !$0.ruby.isEmpty && $0.ruby.allSatisfy(supportedCharacters.contains)
                }
                if !indexableEntries.isEmpty {
                    try DictionaryBuilder.exportDictionary(
                        entries: indexableEntries,
                        to: temporaryURL,
                        baseName: "user",
                        shardByFirstCharacter: false,
                        charIDFileURL: charIDFileURL
                    )
                }
            }

            if let trendStamp {
                try trendStamp.write(
                    to: temporaryURL.appendingPathComponent(Self.trendStampFileName, isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )
            }

            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: directoryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func defaultCharIDFileURL() -> URL? {
        _ = DicdataStore.withDefaultDictionary(preloadDictionary: false)
        let fileManager = FileManager.default
        var resourceURLs = (Bundle.allBundles + Bundle.allFrameworks).compactMap(\.resourceURL)

        if let mainResourceURL = Bundle.main.resourceURL,
           let enumerator = fileManager.enumerator(
            at: mainResourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where url.pathExtension == "bundle" {
                if let bundle = Bundle(url: url), let resourceURL = bundle.resourceURL {
                    resourceURLs.append(resourceURL)
                } else {
                    resourceURLs.append(url.appendingPathComponent("Contents/Resources", isDirectory: true))
                }
            }
        }

        return resourceURLs.lazy
            .map {
                $0.appendingPathComponent("Dictionary/louds/charID.chid", isDirectory: false)
            }
            .first {
                fileManager.fileExists(atPath: $0.path)
            }
    }
}
