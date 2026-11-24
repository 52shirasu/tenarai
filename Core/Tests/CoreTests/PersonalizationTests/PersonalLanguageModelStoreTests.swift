@testable import Core
import Foundation
import Testing

private func temporaryStore() -> (PersonalLanguageModelStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    return (PersonalLanguageModelStore(directory: directory), directory)
}

@Test func appendKeepsNonEmptyLinesOnlyAndIsOwnerOnly() throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(store.append("  確認して下さい \n\n資料を頂いた\n") == 2)
    #expect(store.append("   ") == 0)
    let corpus = try String(contentsOf: store.corpusURL, encoding: .utf8)
    #expect(corpus == "確認して下さい\n資料を頂いた\n")
    let permissions = try FileManager.default.attributesOfItem(atPath: store.corpusURL.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test func modelNeedsEnoughLinesAndEachBuildGetsANewPath() throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    store.append((0..<(PersonalLanguageModelStore.minimumLinesForModel - 1)).map { "テスト\($0)を確認して下さい" }.joined(separator: "\n"))
    #expect(store.train() == false, "too few lines")
    #expect(store.currentModelPrefix() == nil)
    store.append("資料を頂きました\n宜しくお願い致します")
    #expect(store.train())
    let first = try #require(store.currentModelPrefix())
    #expect(PersonalLanguageModelStore.requiredSuffixes.allSatisfy { FileManager.default.fileExists(atPath: first + $0) })
    #expect(store.corpusIsNewerThanModel == false)
    Thread.sleep(forTimeInterval: 0.01)
    store.append("色々な事を試しました")
    #expect(store.train())
    let second = try #require(store.currentModelPrefix())
    // The converter caches models by path, so a rebuild must not reuse it.
    #expect(second != first)
    // A conversion that already took the previous path may still be about to load it.
    #expect(FileManager.default.fileExists(atPath: first + "_c_abc.marisa"), "previous model kept")
    Thread.sleep(forTimeInterval: 0.01)
    store.append("沢山の資料を頂きました")
    #expect(store.train())
    #expect(!FileManager.default.fileExists(atPath: first + "_c_abc.marisa"), "older models removed")
    #expect(FileManager.default.fileExists(atPath: second + "_c_abc.marisa"))
}

@Test func modelBeingWrittenIsNeverPickedUp() throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    store.append((0..<120).map { "文\($0)を確認して下さい" }.joined(separator: "\n"))
    #expect(store.train())
    let complete = try #require(store.currentModelPrefix())
    // A later build whose files exist but are not finished yet.
    let building = directory.appendingPathComponent("models/\(PersonalLanguageModelStore.buildingPrefix)9999999999999")
    try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true)
    for suffix in PersonalLanguageModelStore.requiredSuffixes {
        try Data("partial".utf8).write(to: building.appendingPathComponent("lm" + suffix))
    }
    // A new process (no cached path) looks the model up from disk.
    #expect(PersonalLanguageModelStore(directory: directory).currentModelPrefix() == complete)
    // The next successful build clears the leftover.
    store.append("色々な事を試しました")
    #expect(store.train())
    #expect(!FileManager.default.fileExists(atPath: building.path))
}

@Test func resetDeletesCorpusAndModels() throws {
    let (store, directory) = temporaryStore()
    store.append((0..<120).map { "文\($0)" }.joined(separator: "\n"))
    #expect(store.train())
    store.reset()
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    #expect(store.currentModelPrefix() == nil)
}

@Test func baseModelMustMatchPinnedHashes() throws {
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: resources) }
    let directory = resources.appendingPathComponent("base_n5_lm")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for suffix in PersonalLanguageModelStore.requiredSuffixes {
        try Data("tampered".utf8).write(to: directory.appendingPathComponent("lm" + suffix))
    }
    #expect(PersonalLanguageModelStore.baseModelPrefix(resources: resources) == nil)
}

@Test func pairsRoundTripAndAreTakenOnce() throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    store.appendPair(.init(reading: "カクニン", text: "確認", leftContext: "資料を\t送る\n前に"))
    store.appendPair(.init(reading: "", text: "空", leftContext: ""))
    let permissions = try FileManager.default.attributesOfItem(atPath: store.pairsURL.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(store.takePairs() == [.init(reading: "カクニン", text: "確認", leftContext: "資料を 送る 前に")])
    #expect(store.takePairs().isEmpty)
}

@Test func tuningKeepsDefaultWithoutClearEvidence() {
    var evaluation = PersonalLanguageModelStore.Evaluation()
    evaluation.pairs = 40
    evaluation.matches = ["0.00": 10, "0.10": 10, "0.20": 10, "0.35": 30]
    // Too few clauses.
    #expect(PersonalLanguageModelStore.tune(evaluation) == 0.2)
    evaluation.pairs = 200
    evaluation.matches = ["0.00": 150, "0.10": 152, "0.20": 151, "0.35": 154]
    // 154 - 151 = 3 < margin 4.
    #expect(PersonalLanguageModelStore.tune(evaluation) == 0.2)
    evaluation.matches = ["0.00": 150, "0.10": 152, "0.20": 151, "0.35": 160]
    #expect(PersonalLanguageModelStore.tune(evaluation) == 0.35)
    evaluation.matches = ["0.00": 170, "0.10": 160, "0.20": 151, "0.35": 140]
    #expect(PersonalLanguageModelStore.tune(evaluation) == 0)
}

@Test func evaluationAccumulatesPersistsAndResets() {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(store.tunedAlpha == 0.2)
    store.record(pairs: 30, matches: [0: 20, 0.1: 21, 0.2: 21, 0.35: 26])
    #expect(store.tunedAlpha == 0.2)
    store.record(pairs: 30, matches: [0: 20, 0.1: 21, 0.2: 21, 0.35: 26])
    #expect(store.evaluation().pairs == 60)
    #expect(store.evaluation().matches(alpha: 0.35) == 52)
    #expect(store.tunedAlpha == 0.35)
    #expect(PersonalLanguageModelStore(directory: directory).tunedAlpha == 0.35)
    store.reset()
    #expect(store.tunedAlpha == 0.2)
}

@Test func correctionsAreKeptPrivateAndBounded() throws {
    let (store, directory) = temporaryStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("corrections.tsv")
    func correction(_ chosen: String, shown: String = "以降") -> PersonalLanguageModelStore.Correction {
        .init(reading: "いこう", shown: shown, chosen: chosen, chosenReading: "イコウ", leftContext: "次に\tここへ\n", index: 2)
    }
    store.appendCorrection(correction("行こう"))
    // Nothing was replaced: not a correction.
    store.appendCorrection(correction("以降"))
    var lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 1)
    let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
    #expect(fields.count == 7)
    #expect(Array(fields[1...5]) == ["2", "いこう", "以降", "行こう", "イコウ"])
    #expect(fields[6] == "次に ここへ ")
    let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    for index in 0 ..< PersonalLanguageModelStore.maximumCorrections + 10 {
        store.appendCorrection(correction("行こう\(index)"))
    }
    lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count <= PersonalLanguageModelStore.maximumCorrections)
    #expect(lines.last?.contains("行こう\(PersonalLanguageModelStore.maximumCorrections + 9)") == true)

    store.reset()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
