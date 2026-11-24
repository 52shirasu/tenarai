import Testing

@testable import Core

@Suite("LearningExcludedApps")
struct LearningExcludedAppsTests {
    @Test("カンマ・空白・改行区切りのバンドルIDを読む")
    func parsesSeparators() {
        #expect(Config.LearningExcludedApps.identifiers(in: "com.a.A, com.b.B\ncom.c.C  ,,") == ["com.a.A", "com.b.B", "com.c.C"])
        #expect(Config.LearningExcludedApps.identifiers(in: "").isEmpty)
    }

    @Test("初期値はターミナルとパスワード管理を含む")
    func defaultsCoverTerminalsAndPasswordManagers() {
        let ids = Config.LearningExcludedApps.identifiers(in: Config.LearningExcludedApps.default)
        #expect(ids.contains("com.apple.Terminal"))
        #expect(ids.contains("com.googlecode.iterm2"))
        #expect(ids.contains("com.1password.1password"))
        #expect(!ids.contains("com.apple.TextEdit"))
    }
}
