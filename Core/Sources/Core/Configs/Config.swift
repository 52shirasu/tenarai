import Foundation

/// namespace for `Config`
public enum Config {
    // Synthetic scenarios must neither read nor write the user's preferences.
    // The harness removes this unique suite when the temporary test root is removed.
    public static let testSuiteName: String? = {
        guard let root = ProcessInfo.processInfo.environment["TENARAI_TEST_ROOT"], root.hasPrefix("/") else { return nil }
        return "local.tenarai.tenarai.Tests." + URL(fileURLWithPath: root).lastPathComponent
    }()

    nonisolated(unsafe) public static let userDefaults: UserDefaults = {
        if let testSuiteName {
            return UserDefaults(suiteName: testSuiteName)!
        }
        #if os(macOS)
        return UserDefaults(suiteName: AppGroup.azooKeyMacIdentifier) ?? .standard
        #else
        return .standard
        #endif
    }()

    public static func object(forKey key: String) -> Any? {
        if let value = Self.userDefaults.object(forKey: key) {
            return value
        }
        return testSuiteName == nil ? UserDefaults.standard.object(forKey: key) : nil
    }

    public static func data(forKey key: String) -> Data? {
        if let value = Self.userDefaults.data(forKey: key) {
            return value
        }
        return testSuiteName == nil ? UserDefaults.standard.data(forKey: key) : nil
    }

    public static func string(forKey key: String) -> String? {
        if let value = Self.userDefaults.string(forKey: key) {
            return value
        }
        return testSuiteName == nil ? UserDefaults.standard.string(forKey: key) : nil
    }

    public static func set(_ value: Any?, forKey key: String) {
        Self.userDefaults.set(value, forKey: key)
    }
}

public protocol ConfigItem<Value> {
    static var key: String { get }
    associatedtype Value: Codable
    var value: Value { get nonmutating set }
}
