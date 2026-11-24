@testable import Core
import Foundation
import Testing
import TrendWords

/// 更新プログラム側（TrendWords）は Core に依存せず同じ値を自前で持つ。食い違いがないことを確かめる
@Test func trendWordsLocationsMatchCore() {
    let root = URL(fileURLWithPath: "/tmp/tenaraiTrendLocations", isDirectory: true)
    #expect(TrendWordsLocations.trendFileURL(applicationSupportDirectoryURL: root)
        == TrendWordsStore.fileURL(applicationSupportDirectoryURL: root))
    #expect(TrendWordsLocations.trendWordsKey == Config.TrendWords.key)
    #expect(TrendWordsLocations.appGroupIdentifier == AppGroup.azooKeyMacIdentifier)

    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    #expect(TrendWordsLocations.applicationSupportDirectoryURL(environment: [:], homeDirectoryURL: home)
        == AppGroup.containerURL(homeDirectoryURL: home))
    #expect(TrendWordsLocations.applicationSupportDirectoryURL(environment: ["TENARAI_TEST_ROOT": "/tmp/root"], homeDirectoryURL: home).path
        == "/tmp/root")
    #expect(TrendWordsLocations.applicationSupportDirectoryURL(environment: ["TENARAI_TEST_ROOT": "relative"], homeDirectoryURL: home)
        == AppGroup.containerURL(homeDirectoryURL: home))

    // テスト時のスイート名は Config.testSuiteName と同じ決め方
    #expect(TrendWordsLocations.testSuiteName(environment: [:]) == nil)
    #expect(TrendWordsLocations.testSuiteName(environment: ["TENARAI_TEST_ROOT": "/tmp/abc"]) == "local.tenarai.tenarai.Tests.abc")
    #expect(TrendWordsLocations.testSuiteName() == Config.testSuiteName)
}
