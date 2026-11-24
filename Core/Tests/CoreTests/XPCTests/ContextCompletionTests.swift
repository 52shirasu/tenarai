import Foundation
import Testing
import LearningCore
@testable import Core

@Test func menuPasteDiffHandlesReplacementUnicodeAndDeletion() {
    #expect(ExternalTextChange.insertion(from: "前🙂後", to: "前動画🙂後") == "動画")
    #expect(ExternalTextChange.insertion(from: "古い本文", to: "新しい本文") == "新し")
    #expect(ExternalTextChange.insertion(from: "前後", to: "前") == nil)
    #expect(ExternalTextChange.insertion(from: "同じ", to: "同じ") == nil)
    #expect(ExternalTextChange.insertion(from: "", to: String(repeating: "あ", count: 50000))?.count == 32768)
}

@Test func generalTermsAndContextualLearningWorkBeyondCatalog() async throws {
    let extracted = LocalExtractor.extract("量子もつれと分光分析について検討する。", origin: .typed)
    #expect(extracted.contains { $0.kind == .vocabulary && ($0.value.contains("量子") || $0.value.contains("分光")) })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    for text in ["サーバーを実装する", "APIをサーバーに実装する"] {
        let job = try await store.enqueue(text, origin: .typed)
        _ = try await store.complete(job, observations: LocalExtractor.extract(text, origin: .typed))
    }
    let values = await store.tendencies()
    #expect(LocalExtractor.profile(values, context: "Dockerの設定").contains("システム開発"))
    #expect(!LocalExtractor.profile(values, context: "動画を撮影する").contains("システム開発"))
    #expect(!LocalExtractor.profile(values, context: "動画を撮影する").contains("実装"))
}

@Test func longContextKeepsNearbyTextAndFarTerminology() {
    let near = String(repeating: "あ", count: 180)
    let full = "固有値と行列について計算する。" + near
    let summary = LocalExtractor.compactContext(full + "い", left: true)
    #expect(summary.hasSuffix(String((full + "い").suffix(160))))
    #expect(summary.count <= 200)
    #expect(summary.contains("固有値") || summary.contains("行列"))
}

@Test func spellingVotesRespectExplicitEditsAndDeletion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    for (index, word) in ["サーバー", "サーバ", "サーバ"].enumerated() {
        let job = try await store.enqueue("\(index)\(word)", origin: .typed)
        _ = try await store.complete(job, observations: [.init(key: "spelling:server", kind: .spelling, value: word)])
    }
    #expect(await store.tendencies().first?.value == "サーバ")
    try await store.edit(key: "spelling:server", value: "サーバー")
    let later = try await store.enqueue("new", origin: .typed)
    _ = try await store.complete(later, observations: [.init(key: "spelling:server", kind: .spelling, value: "サーバ")])
    #expect(await store.tendencies().first?.value == "サーバー")
    try await store.delete(key: "spelling:server")
    let fresh = try await store.enqueue("fresh", origin: .typed)
    _ = try await store.complete(fresh, observations: [.init(key: "spelling:server", kind: .spelling, value: "サーバ")])
    #expect(await store.tendencies().first?.value == "サーバ")
}

/// Zenzai reads only the last 25 characters of the profile. The packed profile must
/// fit, start with the field, and keep the strongest items instead of the weakest.
@Test func profileFitsModelWindowAndKeepsStrongestItems() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let texts = Array(repeating: "Dockerのサーバーを再起動して実装を確認する", count: 4)
        + Array(repeating: "データベースの冗長化", count: 2)
        + ["量子もつれの分光分析", "量子もつれの分光分析"]
    for text in texts {
        let job = try await store.enqueue(text, origin: .typed)
        _ = try await store.complete(job, observations: LocalExtractor.extract(text, origin: .typed))
    }
    let profile = LocalExtractor.profile(await store.tendencies(), context: "")
    #expect(profile.count <= LocalExtractor.profileLimit)
    #expect(profile.hasPrefix("システム開発"))
    #expect(profile.contains("サーバー") || profile.contains("Docker"))
    #expect(!profile.contains("分光"), "weaker items must not displace stronger ones")
}

@Test func toneDetectionFromWriting() {
    #expect(LocalExtractor.tones("今日は行かへん。ほんまに疲れたわ") .contains(.kansai))
    #expect(LocalExtractor.tones("それ知らんかったやん") .contains(.kansai))
    #expect(LocalExtractor.tones("ご確認をお願いいたします。") .contains(.polite))
    #expect(LocalExtractor.tones("それなw") .contains(.casual))
    #expect(LocalExtractor.tones("昨日のライブ最高だった笑") .contains(.casual))
    // No false positives from ordinary words.
    #expect(LocalExtractor.tones("たいへんな一日でした").contains(.kansai) == false)
    #expect(LocalExtractor.tones("まじめに取り組む").contains(.casual) == false)
    #expect(LocalExtractor.tones("笑顔で話す").contains(.casual) == false)
    #expect(LocalExtractor.tones("何してんの？").contains(.kansai) == false)
}

@Test func toneExamplePrefersSameAppAndNeedsClearEvidence() {
    func tendency(_ key: String, _ evidence: Double) -> LocalTendency {
        .init(key: key, kind: .tone, value: String(key.split(separator: ":").last!), evidence: evidence)
    }
    let chatKansai = [tendency("tone:関西弁", 6), tendency("tone:敬体", 9),
                      tendency("tone:com.example.chat:関西弁", 5), tendency("tone:com.apple.mail:敬体", 8)]
    let kansai = LocalExtractor.Tone.kansai.example!
    #expect(LocalExtractor.toneExample(chatKansai, app: "com.example.chat") == kansai)
    // Mail is polite: no Kansai example there.
    #expect(LocalExtractor.toneExample(chatKansai, app: "com.apple.mail").isEmpty)
    // An app without its own evidence falls back to all apps, where polite (9) > Kansai (6).
    #expect(LocalExtractor.toneExample(chatKansai, app: "com.new.App").isEmpty)
    #expect(LocalExtractor.toneExample([tendency("tone:関西弁", 6), tendency("tone:敬体", 2)], app: "com.new.App") == kansai)
    #expect(LocalExtractor.toneExample([tendency("tone:関西弁", 2)], app: nil).isEmpty, "too little evidence")
    #expect(LocalExtractor.toneExample([tendency("tone:敬体", 5), tendency("tone:くだけた", 4)], app: nil).isEmpty, "no example for polite/casual")
    // Typed text yields tone observations; pasted text does not.
    #expect(LocalExtractor.extract("ほんまにそうやねん", origin: .typed, app: "x").contains { $0.key == "tone:x:関西弁" })
    #expect(!LocalExtractor.extract("ほんまにそうやねん", origin: .pasted, app: "x").contains { $0.kind == .tone })
    // Tone items never enter the vocabulary profile.
    #expect(!LocalExtractor.profile(chatKansai, context: "").contains("関西弁"))
}

@Test func kansaiNegativeBeforeParticleIsDetected() {
    #expect(LocalExtractor.tones("今日は行かへんわ").contains(.kansai))
    #expect(LocalExtractor.tones("できへんかった").contains(.kansai))
    #expect(!LocalExtractor.tones("そのへんに置いといて").contains(.kansai))
}
