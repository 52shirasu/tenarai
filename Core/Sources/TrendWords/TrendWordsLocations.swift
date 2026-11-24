import Foundation

/// 流行語の一覧の場所と設定の読み取り
///
/// `Core` の `AppGroup`・`Config`・`TrendWordsStore` と同じ値を自前で持つ
/// （通信するプログラムに `Core` を混ぜないため）。一致は CoreTests で確かめる。
public enum TrendWordsLocations {
    public static let appGroupIdentifier = "group.local.tenarai.inputmethod.tenarai"
    /// `Config.TrendWords.key` と同じ
    public static let trendWordsKey = "local.tenarai.inputmethod.tenarai.preference.enableTrendWords"
    static let testRootVariable = "TENARAI_TEST_ROOT"

    /// データの場所。`TENARAI_TEST_ROOT`（`/` 始まり）があればそこ、なければ
    /// `~/Library/Application Support/tenarai`
    public static func applicationSupportDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let testRoot = environment[Self.testRootVariable], testRoot.hasPrefix("/") {
            return URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        return homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("tenarai", isDirectory: true)
    }

    public static func trendDirectoryURL(applicationSupportDirectoryURL: URL) -> URL {
        applicationSupportDirectoryURL.appendingPathComponent("trend", isDirectory: true)
    }

    /// `TrendWordsStore.fileURL(applicationSupportDirectoryURL:)` と同じ
    public static func trendFileURL(applicationSupportDirectoryURL: URL) -> URL {
        Self.trendDirectoryURL(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
            .appendingPathComponent("trend.tsv", isDirectory: false)
    }

    public static func statusFileURL(applicationSupportDirectoryURL: URL) -> URL {
        Self.trendDirectoryURL(applicationSupportDirectoryURL: applicationSupportDirectoryURL)
            .appendingPathComponent("status.json", isDirectory: false)
    }

    /// テスト時の設定スイート名（`Config.testSuiteName` と同じ決め方）
    public static func testSuiteName(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let root = environment[Self.testRootVariable], root.hasPrefix("/") else {
            return nil
        }
        return "local.tenarai.tenarai.Tests." + URL(fileURLWithPath: root).lastPathComponent
    }

    /// 流行語の設定がオンか。値がなければ true（`Config.TrendWords` と同じ）
    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let testSuiteName = Self.testSuiteName(environment: environment)
        let suite: UserDefaults
        if let testSuiteName {
            guard let testSuite = UserDefaults(suiteName: testSuiteName) else {
                return true
            }
            suite = testSuite
        } else {
            suite = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        }
        let value = suite.object(forKey: Self.trendWordsKey)
            ?? (testSuiteName == nil ? UserDefaults.standard.object(forKey: Self.trendWordsKey) : nil)
        guard let value else {
            return true
        }
        return value as? Bool ?? true
    }
}
