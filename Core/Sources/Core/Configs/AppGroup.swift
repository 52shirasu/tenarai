import Foundation

public enum AppGroup {
    public static let azooKeyMacIdentifier = "group.local.tenarai.inputmethod.tenarai"

    #if os(macOS)
    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        if let testRoot = ProcessInfo.processInfo.environment["TENARAI_TEST_ROOT"], testRoot.hasPrefix("/") {
            return URL(fileURLWithPath: testRoot, isDirectory: true)
        }
        return Self.containerURL(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser)
    }

    /// Personal ad-hoc build: client and helper share an isolated local directory.
    public static func containerURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("tenarai", isDirectory: true)
    }

    public static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let containerURL = Self.containerURL(fileManager: fileManager) {
            return containerURL
        }

        if #available(macOS 13, *) {
            return URL.applicationSupportDirectory
                .appending(path: "tenarai", directoryHint: .isDirectory)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("tenarai", isDirectory: true)
    }

    public static func memoryDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("memory", isDirectory: true)
    }
    #endif
}
