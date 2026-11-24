import Foundation

/// Bounded offline suggestions; never modifies composition or confirmed text.
enum JapaneseTypoCandidates {
    struct Entry { let roman: String; let reading: String; let text: String }
    static let entries: [Entry] = [
        .init(roman: "ohayougozaimasu", reading: "おはようございます", text: "おはようございます"),
        .init(roman: "arigatougozaimasu", reading: "ありがとうございます", text: "ありがとうございます"),
        .init(roman: "arigatougozaimashita", reading: "ありがとうございました", text: "ありがとうございました"),
        .init(roman: "arigatougozaimasita", reading: "ありがとうございました", text: "ありがとうございました"),
        .init(roman: "yoroshikuonegaishimasu", reading: "よろしくおねがいします", text: "よろしくお願いします"),
        .init(roman: "yorosikuonegaisimasu", reading: "よろしくおねがいします", text: "よろしくお願いします"),
        .init(roman: "otsukaresamadesu", reading: "おつかれさまです", text: "お疲れ様です"),
        .init(roman: "otukaresamadesu", reading: "おつかれさまです", text: "お疲れ様です"),
        .init(roman: "otsukaresamadeshita", reading: "おつかれさまでした", text: "お疲れ様でした"),
        .init(roman: "otsukaresamadesita", reading: "おつかれさまでした", text: "お疲れ様でした"),
        .init(roman: "sumimasen", reading: "すみません", text: "すみません"),
        .init(roman: "gomennasai", reading: "ごめんなさい", text: "ごめんなさい"),
        .init(roman: "moushiwakearimasen", reading: "もうしわけありません", text: "申し訳ありません"),
        .init(roman: "mousiwakearimasen", reading: "もうしわけありません", text: "申し訳ありません"),
        .init(roman: "wakarimashita", reading: "わかりました", text: "分かりました"),
        .init(roman: "wakarimasita", reading: "わかりました", text: "分かりました"),
        .init(roman: "shouchishimashita", reading: "しょうちしました", text: "承知しました"),
        .init(roman: "kakuninshimasu", reading: "かくにんします", text: "確認します"),
        .init(roman: "kakuninsimasu", reading: "かくにんします", text: "確認します"),
        .init(roman: "kakuninonegaishimasu", reading: "かくにんおねがいします", text: "確認お願いします"),
        .init(roman: "daijoubudesu", reading: "だいじょうぶです", text: "大丈夫です"),
        .init(roman: "daizyoubudesu", reading: "だいじょうぶです", text: "大丈夫です"),
        .init(roman: "omataseshimashita", reading: "おまたせしました", text: "お待たせしました"),
        .init(roman: "osakinishitsureishimasu", reading: "おさきにしつれいします", text: "お先に失礼します"),
        .init(roman: "itsumoosewaninatteorimasu", reading: "いつもおせわになっております", text: "いつもお世話になっております")
    ]

    static func suggestions(raw: String, reading: String, personal: [Config.UserDictionaryEntry] = []) -> [String] {
        guard (5...64).contains(raw.count), reading.count <= 64 else { return [] }
        // Correctly typed bundled phrases must not be nudged to a different phrase.
        guard !entries.contains(where: { $0.roman == raw || $0.reading == reading }) else { return [] }
        var result: [String] = []
        for entry in entries where oneEdit(raw, entry.roman) || oneEdit(reading, entry.reading) {
            if !result.contains(entry.text) { result.append(entry.text) }
        }
        for entry in personal.prefix(512) where (5...64).contains(entry.reading.count) && !entry.word.isEmpty && entry.word.count <= 64 {
            if oneEdit(reading, entry.reading), !result.contains(entry.word) { result.append(entry.word) }
        }
        return Array(result.prefix(3))
    }

    /// Corrections from the curated fixed phrases only, never from personal words.
    static func phraseCorrections(raw: String, reading: String) -> [String] {
        suggestions(raw: raw, reading: reading, personal: [])
    }

    /// Exactly one insertion, deletion, substitution, or adjacent transposition.
    static func oneEdit(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        var i = 0
        while i < min(a.count, b.count), a[i] == b[i] { i += 1 }
        if a.count == b.count {
            if Array(a.dropFirst(i + 1)) == Array(b.dropFirst(i + 1)) { return true }
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i]
                && Array(a.dropFirst(i + 2)) == Array(b.dropFirst(i + 2))
        }
        if a.count < b.count { return Array(a.dropFirst(i)) == Array(b.dropFirst(i + 1)) }
        return Array(a.dropFirst(i + 1)) == Array(b.dropFirst(i))
    }
}
