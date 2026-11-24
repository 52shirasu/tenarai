@testable import Core
import Foundation
import Testing

/// Builds a loudstxt3 file the way azooKey writes it.
private func loudstxt3(_ entries: [(ruby: String, words: [String])]) -> Data {
    var payloads: [Data] = []
    for entry in entries {
        var d = Data()
        var count = UInt16(entry.words.count)
        d.append(Data(bytes: &count, count: 2))
        d.append(Data(repeating: 1, count: 10 * entry.words.count))
        d.append(([entry.ruby] + entry.words.map { $0 == entry.ruby ? "" : $0 }).joined(separator: "\t").data(using: .utf8)!)
        payloads.append(d)
    }
    var result = Data()
    var n = UInt16(entries.count)
    result.append(Data(bytes: &n, count: 2))
    var offset = UInt32(2 + 4 * entries.count)
    for p in payloads {
        result.append(Data(bytes: &offset, count: 4))
        offset += UInt32(p.count)
    }
    payloads.forEach { result.append($0) }
    return result
}

@Test func readsLearnedConversionsAndFlagsRomajiFragments() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try loudstxt3([("ゴヘンカン", ["ご変換", "誤変換"]), ("オk", ["おk"]), ("サーバー", ["サーバー"])])
        .write(to: directory.appendingPathComponent("memory0.loudstxt3"))
    let items = LearningMemoryReader.conversions(in: directory)
    #expect(items.contains(.init(reading: "ゴヘンカン", word: "ご変換")))
    #expect(items.contains(.init(reading: "ゴヘンカン", word: "誤変換")))
    #expect(items.contains(.init(reading: "サーバー", word: "サーバー")), "empty word means same as reading")
    #expect(items.filter(\.hasPendingRomaji) == [.init(reading: "オk", word: "おk")])
}
