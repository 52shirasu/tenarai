import Foundation

/// Reads the words stored in azooKey's learning memory (`memory*.loudstxt3`).
public enum LearningMemoryReader {
    public static func conversions(in directory: URL) -> [LearnedConversion] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [LearnedConversion] = []
        var seen = Set<LearnedConversion>()
        for name in names.sorted() where name.hasPrefix("memory") && name.hasSuffix(".loudstxt3") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)), data.count >= 2 else { continue }
            for item in parse(data) where seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Format: UInt16 entry count, UInt32 offsets, then per entry a UInt16 row count,
    /// 10 bytes per row, and "ruby\tword\tword..." (empty word = same as ruby).
    static func parse(_ data: Data) -> [LearnedConversion] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        let count = u16(0)
        guard bytes.count >= 2 + 4 * count else { return [] }
        let offsets = (0..<count).map { u32(2 + 4 * $0) } + [bytes.count]
        var result: [LearnedConversion] = []
        for i in 0..<count {
            let start = offsets[i], end = offsets[i + 1]
            guard start + 2 <= end, end <= bytes.count else { continue }
            let rows = u16(start)
            let textStart = start + 2 + 10 * rows
            guard textStart <= end, let text = String(bytes: bytes[textStart..<end], encoding: .utf8) else { continue }
            let fields = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let reading = fields.first else { continue }
            for word in fields.dropFirst() {
                result.append(.init(reading: reading, word: word.isEmpty ? reading : word))
            }
        }
        return result
    }
}
