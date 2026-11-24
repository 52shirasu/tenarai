import AppKit

/// Invoked only by explicit conversion, never while typing. No network inference.
enum LatinConversionCandidates {
    // Small precomputed index; no full dictionary scan or English-to-romaji transliteration.
    private static let readings: [String: [String]] = {
        guard let url = Bundle.module.url(forResource: "LatinReadings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return result
    }()

    static func katakana(for input: String) -> [String] {
        readings[input.lowercased()] ?? []
    }

    @MainActor static func words(for input: String, personal: [Config.UserDictionaryEntry] = []) -> [String] {
        guard !input.isEmpty, input.utf16.count <= 128,
              input.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "'-".unicodeScalars.contains($0)) }) else {
            return [input]
        }
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: input.utf16.count)
        let completions = checker.completions(forPartialWordRange: range, in: input,
                                             language: "en_US", inSpellDocumentWithTag: 0) ?? []
        // Keep spelling/capitalization corrections, not unrelated guesses such as Docker -> Locker.
        let guesses = checker.guesses(forWordRange: range, in: input,
                                      language: "en_US", inSpellDocumentWithTag: 0) ?? []
        return personalized(input: input, base: ordered(input: input, completions: completions, guesses: guesses), entries: personal)
    }

    static func validName(_ word: String) -> Bool {
        (3...64).contains(word.count) && word.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
            && word.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "'-".unicodeScalars.contains($0)) }
    }

    static func personalized(input: String, base: [String], entries: [Config.UserDictionaryEntry]) -> [String] {
        guard validName(input) else { return base }
        let lower = input.lowercased(), limit = input.count >= 6 ? 2 : 1
        var matches: [(Config.UserDictionaryEntry, Int)] = []
        for entry in entries where validName(entry.word) && abs(entry.word.count - input.count) <= limit {
            let distance = editDistance(lower, entry.word.lowercased())
            if distance <= limit { matches.append((entry, distance)) }
        }
        matches.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.word < $1.0.word
        }
        let best = matches.first?.1
        let chosen = matches.filter { $0.1 == best }.prefix(4)
        var additions: [String] = []
        for (entry, _) in chosen {
            additions.append(entry.word)
            let reading = entry.reading.applyingTransform(.hiraganaToKatakana, reverse: false) ?? ""
            if !reading.isEmpty && reading.unicodeScalars.allSatisfy({ (0x30A1...0x30FA).contains(Int($0.value)) || $0.value == 0x30FC }) {
                additions.append(reading)
            }
            additions += katakana(for: entry.word)
        }
        // Exact dictionary spelling may fix case; a speculative correction never displaces the original.
        let result = best == 0 ? additions + [input] + base : [input] + additions + base
        guard !additions.isEmpty else { return base }
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0).inserted }.prefix(20))
    }

    static func ordered(input: String, completions: [String], guesses: [String]) -> [String] {
        let variants = (completions + guesses).filter { $0 != input && $0.lowercased() == input.lowercased() }
        // A known word should not receive speculative corrections (e.g. Docker -> Locker).
        let isKnown = readings[input.lowercased()] != nil || completions.contains(input)
        let scored = isKnown ? [] : guesses.compactMap { guess -> (String, Int)? in
            guard !guess.isEmpty, guess.lowercased() != input.lowercased(),
                  guess.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.letters.contains($0) || "'-".unicodeScalars.contains($0)) }) else { return nil }
            let distance = editDistance(input.lowercased(), guess.lowercased())
            return distance <= (input.count >= 6 ? 2 : 1) ? (guess, distance) : nil
        }
        let closest = scored.map(\.1).min()
        let corrections = scored.filter { $0.1 == closest }.prefix(4).map(\.0)
        var seen = Set<String>()
        let exact = variants + [input] + katakana(for: input)
        let suggested = corrections.flatMap { [$0] + katakana(for: $0) }
        return Array((exact + suggested + completions).filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(20))
    }

    /// Adjacent transpositions count as one edit.
    private static func editDistance(_ source: String, _ target: String) -> Int {
        let a = Array(source), b = Array(target)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count), beforePrevious = previous
        for i in 1...a.count {
            var row = Array(repeating: 0, count: b.count + 1)
            row[0] = i
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1,
                             previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                    row[j] = min(row[j], beforePrevious[j - 2] + 1)
                }
            }
            beforePrevious = previous
            previous = row
        }
        return previous[b.count]
    }
}
