import Foundation
import NaturalLanguage

/// Local linguistic analysis; no model downloads, network or history retrieval.
public enum LocalExtractor {
    private static let domains: [(String, [String])] = [
        ("システム開発", ["サーバー", "サーバ", "コンテナ", "Docker", "API", "データベース", "実装", "デプロイ", "再起動", "冗長化", "DNS", "LLM"]),
        ("数学・統計", ["方程式", "微分", "積分", "行列", "固有値", "確率", "統計", "定理", "証明", "関数", "ベクトル"]),
        ("撮影・映像", ["動画", "撮影", "カメラ", "レンズ", "録画", "写真"]),
        ("医療・生命科学", ["細胞", "遺伝子", "蛋白質", "診療", "免疫", "臨床"]),
        ("法律", ["判例", "訴訟", "民法", "刑法", "裁判", "契約"]),
        ("経済・会計", ["会計", "決算", "財務", "仕訳", "金融", "簿記"])
    ]

    public static func terms(_ text: String, limit: Int = 32) -> [String] {
        let bounded = String(text.prefix(32768))
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = bounded
        var result: [String] = []
        var seen = Set<String>()
        tagger.enumerateTags(in: bounded.startIndex..<bounded.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let word = String(bounded[range])
            if (tag == .noun || tag == .otherWord), (2...40).contains(word.count),
               word.contains(where: { !$0.isNumber }), seen.insert(word).inserted {
                result.append(word)
            }
            return result.count < limit
        }
        return result
    }

    /// Keep nearby verbatim text and bounded keywords from farther in the same field.
    public static func compactContext(_ text: String, left: Bool, limit: Int = 200) -> String {
        guard text.count > limit else { return text }
        let nearCount = max(0, limit - 40)
        let near = left ? String(text.suffix(nearCount)) : String(text.prefix(nearCount))
        let far = left ? String(text.dropLast(nearCount)) : String(text.dropFirst(nearCount))
        let summary = String(terms(far, limit: 8).joined(separator: "、").prefix(32))
        return left ? "〔\(summary)〕…" + near : near + "…〔\(summary)〕"
    }

    // MARK: tone (counts only; the text itself is never kept)
    public enum Tone: String, CaseIterable, Sendable {
        case kansai = "関西弁", polite = "敬体", casual = "くだけた"

        /// A fixed sentence in this tone, given as context for an empty field. Zenzai
        /// follows tone from context but not from its profile/style conditions.
        /// Measured (Oct 5): Kansai +6/60 on empty-field Kansai input with no loss on
        /// standard text; polite and casual examples brought no gain, so they have none.
        public var example: String? {
            switch self {
            case .kansai: "せやな、ほんまにそう思うわ。"
            case .polite, .casual: nil
            }
        }
    }

    private static let end = "(?=[。、！？!?」』）)\\s笑w]|$)"
    private static let tonePatterns: [(Tone, NSRegularExpression)] = [
        (.kansai, try! NSRegularExpression(pattern:
            "(やん|やねん|てん|んねん|やで|やろ|やな|やわ|ちゃう|ちゃうん|あかん|あらへん|かまへん|おおきに)" + end
            // Negative "-へん" (行かへん) is followed by わ/で/から etc.; the stem kana excludes たいへん/その辺.
            + "|[かがさたなまらわけせてねめれきこみびにちじ]へん|いいへん|しいへん|せえへん|けえへん|めっちゃ|ほんま|せやな|せやけど|しんどい|おもろ|なんぼ")),
        (.polite, try! NSRegularExpression(pattern: "(です|ます|ました|ません|ください|でしょう|ございます|ましょう)" + end)),
        (.casual, try! NSRegularExpression(pattern: "笑(?=[。、！？!?）)\\s]|$)|(?<![A-Za-z])w{1,4}$|まじ(?!め)|マジ|やば|ヤバ|じゃん|だよね|てか|それな"))
    ]

    /// Tones the writer used in this text.
    public static func tones(_ text: String) -> [Tone] {
        let bounded = String(text.prefix(4096))
        let range = NSRange(bounded.startIndex..., in: bounded)
        return tonePatterns.filter { $0.1.firstMatch(in: bounded, range: range) != nil }.map(\.0)
    }

    /// Example sentence for the tone this writer clearly uses, preferring evidence from
    /// the same app (chat and e-mail differ) and falling back to all apps.
    public static func toneExample(_ tendencies: [LearningStore.Tendency], app: String?, minimumEvidence: Double = 3) -> String {
        func evidence(prefix: String) -> [Tone: Double] {
            var result: [Tone: Double] = [:]
            for item in tendencies where item.kind == .tone {
                for tone in Tone.allCases where item.key == prefix + tone.rawValue {
                    result[tone] = item.evidence
                }
            }
            return result
        }
        var counts = app.map { evidence(prefix: "tone:\($0):") } ?? [:]
        if counts.values.reduce(0, +) < minimumEvidence {
            counts = evidence(prefix: "tone:")
        }
        let kansai = counts[.kansai] ?? 0, polite = counts[.polite] ?? 0
        // Polite writing in this app (e-mail) outweighs a Kansai habit from elsewhere.
        if kansai >= minimumEvidence, kansai >= polite, let example = Tone.kansai.example {
            return example
        }
        return ""
    }

    public static func extract(_ text: String, origin: LearningStore.Origin, app: String? = nil) -> [LearningStore.Observation] {
        var result: [LearningStore.Observation] = []
        // Only the user's own typing says how they write; pasted text does not.
        if origin == .typed {
            for tone in tones(text) {
                result.append(.init(key: "tone:\(tone.rawValue)", kind: .tone, value: tone.rawValue))
                if let app, !app.isEmpty, app.count <= 96 {
                    result.append(.init(key: "tone:\(app):\(tone.rawValue)", kind: .tone, value: tone.rawValue))
                }
            }
        }
        let bounded = String(text.prefix(32768))
        for (domain, words) in domains {
            let found = words.filter { bounded.localizedCaseInsensitiveContains($0) }
            if !found.isEmpty {
                result.append(.init(key: "domain:\(domain)", kind: .domain, value: domain))
                result += found.map { .init(key: "word:\($0)", kind: .vocabulary, value: $0) }
            }
        }
        result += terms(bounded).map { .init(key: "word:\($0)", kind: .vocabulary, value: $0) }
        if origin == .typed {
            for (key, long, short) in [("server", "サーバー", "サーバ"), ("user", "ユーザー", "ユーザ")] {
                if bounded.contains(long) {
                    result.append(.init(key: "spelling:\(key)", kind: .spelling, value: long))
                } else if bounded.contains(short) {
                    result.append(.init(key: "spelling:\(key)", kind: .spelling, value: short))
                }
            }
            // Learn actual written variants of arbitrary Latin technical words too.
            for word in terms(bounded) where word.unicodeScalars.allSatisfy({ $0.isASCII }) {
                result.append(.init(key: "spelling:latin:\(word.lowercased())", kind: .spelling, value: word))
            }
        }
        return result
    }

    public static func profile(_ tendencies: [LearningStore.Tendency], context: String) -> String {
        let activeDomains = domains.filter { _, words in words.contains { context.localizedCaseInsensitiveContains($0) } }
        let conflictingWords = Set(domains.filter { domain, _ in
            !activeDomains.isEmpty && !activeDomains.contains { $0.0 == domain }
        }.flatMap(\.1))
        let eligible = tendencies.filter {
            guard $0.evidence >= 2, $0.kind != .tone else { return false }
            if $0.kind == .spelling { return true }
            if $0.kind == .domain { return true }
            return !conflictingWords.contains($0.value)
        }.filter { item in
            item.kind != .domain || activeDomains.isEmpty || activeDomains.contains { $0.0 == item.value }
        }
        // Decide "appears in the context" once per item. Doing it inside the comparator
        // ran two locale-aware searches per comparison: with a terminal's long context
        // and ~1,600 tendencies the first key of each composition took 5.6 s (Oct 11).
        .map { (item: $0, inContext: context.localizedCaseInsensitiveContains($0.value)) }
        .sorted {
            // The field (domain) is the strongest attribute; keep it ahead of words.
            if ($0.item.kind == .domain) != ($1.item.kind == .domain) { return $0.item.kind == .domain }
            if $0.inContext != $1.inContext { return $0.inContext }
            return $0.item.evidence == $1.item.evidence ? $0.item.key < $1.item.key : $0.item.evidence > $1.item.evidence
        }
        .map(\.item)
        let mode = ProcessInfo.processInfo.environment["TENARAI_TEST_PROFILE"]
        if mode == "legacy" {
            return String(eligible.prefix(context.isEmpty ? 16 : 8).map(\.value).joined(separator: "、").prefix(160))
        }
        // With surrounding text, the text decides; pass only attributes it supports
        // (a field its words belong to, or learned words it contains). A field learned
        // from other writing must not override, e.g., 機会 in a chat about a friend.
        let supported = context.isEmpty || mode == "packed" ? eligible : eligible.filter { item in
            item.kind == .domain ? activeDomains.contains { $0.0 == item.value } : context.localizedCaseInsensitiveContains(item.value)
        }
        return pack(supported.prefix(context.isEmpty ? 16 : 8).map(\.value), limit: profileLimit)
    }

    /// Zenzai reads only the last 25 characters of the profile (10-20 recommended).
    /// A longer list lost its most important leading items, so pack whole items in
    /// priority order within this limit instead.
    public static let profileLimit = 24

    static func pack(_ values: [String], limit: Int) -> String {
        var result = ""
        for value in values {
            let candidate = result.isEmpty ? value : result + "、" + value
            if candidate.count > limit { continue }
            result = candidate
        }
        return result
    }

    public static func profile(_ tendencies: [LearningStore.Tendency], hasContext: Bool) -> String {
        hasContext ? "" : profile(tendencies, context: "")
    }
}
