import Foundation
import LearningCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func deadlineSurvivesFailureRetryAndRestart() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date(timeIntervalSince1970: 1_000_000)
    let store = try LearningStore(directory: directory, now: start)
    let job = try await store.enqueue("テスト原文", origin: .typed, now: start)
    try await store.failed(job, now: start.addingTimeInterval(3600))
    let retry = try await store.enqueue("テスト原文", origin: .typed, now: start.addingTimeInterval(7200))
    check(retry.id == job.id)
    check(retry.expiresAt == job.expiresAt)
    let restored = try LearningStore(directory: directory, now: job.expiresAt)
    check(try await restored.pending(now: job.expiresAt).isEmpty)
    check(!String(decoding: try Data(contentsOf: directory.appendingPathComponent("learning.json")), as: UTF8.self).contains("テスト原文"))
}

func deletionRejectsInflightResultButAllowsNewLearning() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let observation = LearningStore.Observation(key: "domain:development", kind: .domain, value: "システム開発")
    let job = try await store.enqueue("最初の入力", origin: .typed)
    check(try await store.complete(job, observations: [observation]))
    let inflight = try await store.enqueue("処理中の入力", origin: .typed)
    try await store.delete(key: observation.key)
    check(try await store.pending().isEmpty)
    check(try await !store.complete(inflight, observations: [observation]))
    check(await store.tendencies().isEmpty)
    let fresh = try await store.enqueue("新しい入力", origin: .typed)
    check(try await store.complete(fresh, observations: [observation]))
    check(await store.tendencies().count == 1)
}

func successfulExtractionRemovesRawTextAndCannotReplay() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let job = try await store.enqueue("保存後に消すテスト原文", origin: .typed)
    check(try await store.complete(job, observations: []))
    check(try await !store.complete(job, observations: []))
    let contents = try String(contentsOf: directory.appendingPathComponent("learning.json"), encoding: .utf8)
    check(!contents.contains(job.text))
}

func pastedTextHasLowerWeightAndDoesNotTeachSpelling() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let topic = LearningStore.Observation(key: "domain:math", kind: .domain, value: "数学")
    let spelling = LearningStore.Observation(key: "spelling:server", kind: .spelling, value: "サーバー")
    let paste = try await store.enqueue("引用した文章", origin: .pasted)
    check(try await store.complete(paste, observations: [topic, topic, spelling]))
    let first = await store.tendencies()
    check(first.count == 1)
    check(first.first?.evidence == 0.25)
    let typed = try await store.enqueue("自分の文章", origin: .typed)
    check(try await store.complete(typed, observations: [topic, spelling]))
    let second = await store.tendencies()
    check(second.first(where: { $0.key == topic.key })?.evidence == 1.25)
    check(second.contains(where: { $0.key == spelling.key }))
}

func expiredResultIsRejectedAndCapacityIsBounded() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = Date()
    let store = try LearningStore(directory: directory, now: start, maxPendingBytes: 4)
    let job = try await store.enqueue("abcd", origin: .typed, now: start)
    do {
        _ = try await store.enqueue("e", origin: .typed, now: start)
        fatalError("capacity limit not enforced")
    } catch LearningStore.StoreError.capacityExceeded {}
    check(try await !store.complete(job, observations: [], now: job.expiresAt))
}

func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, "check failed", file: file, line: line)
}

func repeatedPasteDoesNotAccumulate() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let observation = LearningStore.Observation(key: "math", kind: .domain, value: "数学")
    for _ in 0..<3 {
        let job = try await store.enqueue("同じ貼り付け文", origin: .pasted)
        check(try await store.complete(job, observations: [observation]))
    }
    check(await store.tendencies().first?.evidence == 0.25)
    try await store.deleteAll()
    let job = try await store.enqueue("同じ貼り付け文", origin: .pasted)
    check(try await store.complete(job, observations: [observation]))
    check(await store.tendencies().first?.evidence == 0.25)
}

func extractorAndContextPolicy() async throws {
    let observations = LocalExtractor.extract("DockerコンテナとAPIをサーバーに実装する", origin: .typed)
    check(observations.contains { $0.kind == .domain && $0.value == "システム開発" })
    check(observations.contains { $0.kind == .spelling && $0.value == "サーバー" })
    check(!LocalExtractor.extract("サーバー", origin: .pasted).contains { $0.kind == .spelling })
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    for text in ["DockerのAPI", "サーバーの実装"] {
        let job = try await store.enqueue(text, origin: .typed)
        _ = try await store.complete(job, observations: LocalExtractor.extract(text, origin: .typed))
    }
    let tendencies = await store.tendencies()
    check(LocalExtractor.profile(tendencies, hasContext: true).isEmpty)
    check(!LocalExtractor.profile(tendencies, hasContext: false).isEmpty)
    let inflight = try await store.enqueue("編集前の入力", origin: .typed)
    try await store.edit(key: "domain:システム開発", value: "情報システム")
    check(try await !store.complete(inflight, observations: observations))
    check(await store.tendencies().contains { $0.value == "情報システム" })
}

func transientSecurityScenarios() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LearningStore(directory: directory)
    let original = "PRIVATE-SYNTHETIC-ORIGINAL-987654"
    try await store.learnTransient(original, origin: .typed, observations: [])
    let file = directory.appendingPathComponent("learning.json")
    check(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(original))
    do {
        try await store.learnTransient(original, origin: .typed,
            observations: [.init(key: "", kind: .spelling, value: "")])
        fatalError("invalid observation accepted")
    } catch LearningStore.StoreError.invalidObservation { }
    check(try await store.pending().isEmpty)
    check(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(original))
    _ = try await store.enqueue(original, origin: .typed)
    try await store.discardPending()
    _ = try await store.enqueue(original, origin: .typed)
    let restored = try LearningStore(directory: directory, discardPending: true)
    check(try await restored.pending().isEmpty)
    check(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(original))
    check(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@main struct Checks {
    static func main() async throws {
        try await deadlineSurvivesFailureRetryAndRestart()
        try await deletionRejectsInflightResultButAllowsNewLearning()
        try await successfulExtractionRemovesRawTextAndCannotReplay()
        try await pastedTextHasLowerWeightAndDoesNotTeachSpelling()
        try await expiredResultIsRejectedAndCapacityIsBounded()
        try await repeatedPasteDoesNotAccumulate()
        try await extractorAndContextPolicy()
        try await transientSecurityScenarios()
        print("PASS: 8 learning-store and extraction scenarios including transient security")
    }
}
