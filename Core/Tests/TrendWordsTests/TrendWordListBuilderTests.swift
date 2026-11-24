import Foundation
import Testing
@testable import TrendWords

private struct Fixture {
    var directoryURL: URL
    var dictionaryURL: URL
    var pageviewURLs: [URL]
    var loudsURL: URL
}

private func makeFixture(
    dictionary: String,
    months: [String: [(String, Int)]],
    shards: [String: Data] = [:]
) throws -> Fixture {
    let directoryURL = try makeTemporaryDirectoryURL()
    let dictionaryURL = directoryURL.appendingPathComponent("SKK-JISYO.jawiki")
    try Data(dictionary.utf8).write(to: dictionaryURL)
    var pageviewURLs: [URL] = []
    for (name, articles) in months {
        let url = directoryURL.appendingPathComponent("top-\(name).json")
        try pageviewsJSON(articles).write(to: url)
        pageviewURLs.append(url)
    }
    let loudsURL = directoryURL.appendingPathComponent("louds", isDirectory: true)
    try FileManager.default.createDirectory(at: loudsURL, withIntermediateDirectories: true)
    for (name, data) in shards {
        try data.write(to: loudsURL.appendingPathComponent(name))
    }
    return Fixture(directoryURL: directoryURL, dictionaryURL: dictionaryURL, pageviewURLs: pageviewURLs, loudsURL: loudsURL)
}

private func build(_ fixture: Fixture) throws -> TrendWordListBuilder.Output {
    try TrendWordListBuilder.build(
        readingDictionaryURL: fixture.dictionaryURL,
        pageviewURLs: fixture.pageviewURLs,
        loudsDirectoryURL: fixture.loudsURL
    )
}

@Test func titlesAreNormalizedAndViewsAreSummedAcrossMonths() throws {
    let fixture = try makeFixture(
        dictionary: """
        ;; comment /無視/
        なかむらゆり /中村ゆり/
        ゆきだるま /Snow Man;グループ/雪だるま/

        """,
        months: [
            "2026-01": [("中村ゆり_(女優)", 100), ("Snow_Man", 50), ("Wikipedia:索引", 999), ("メインページ", 999), ("特別:検索", 999)],
            "2026-02": [("中村ゆり", 30)]
        ]
    )
    let output = try build(fixture)
    #expect(output.kept == [
        .init(reading: "なかむらゆり", word: "中村ゆり", views: 130, months: 2),
        .init(reading: "ゆきだるま", word: "Snow Man", views: 50, months: 1)
    ])
    #expect(output.articleCount == 2)
}

@Test func normalizeTitleMatchesPythonRegex() {
    #expect(TrendWordListBuilder.normalizeTitle("中村ゆり_(女優)") == "中村ゆり")
    #expect(TrendWordListBuilder.normalizeTitle("A_(b)_(c)") == "A")
    #expect(TrendWordListBuilder.normalizeTitle("A_()") == "A")
    #expect(TrendWordListBuilder.normalizeTitle("A_(b") == "A (b")
    #expect(TrendWordListBuilder.normalizeTitle("A_)") == "A )")
    #expect(TrendWordListBuilder.normalizeTitle("Snow_Man") == "Snow Man")
}

@Test func titlesAreSkippedForEachReason() throws {
    let fixture = try makeFixture(
        dictionary: """
        あいう /あいう/
        えー /AB/
        ちょうい /ABCDEFGHIJKLMNO/
        いち /一/
        とうきょうじけん /東京事件/
        せいぎょ /A\u{200B}B/
        Abc /英字読み/
        かくさん /拡散/
        かくさんにばん /拡散/

        """,
        months: [
            "2026-01": [
                ("あいう", 90), ("AB", 80), ("ABCDEFGHIJKLMNO", 70), ("一", 60),
                ("東京事件", 50), ("A\u{200B}B", 40), ("英字読み", 30), ("読みのない題名", 20), ("拡散", 10)
            ]
        ]
    )
    let output = try build(fixture)
    #expect(output.kept == [.init(reading: "かくさん", word: "拡散", views: 10, months: 1)])
    #expect(output.skipped == ["ひらがなだけ": 1, "読みが短い": 1, "長さ": 2, "出来事など": 2, "読みが分からない": 2])
}

@Test func annotationsAreRemovedAndFirstReadingWins() throws {
    let fixture = try makeFixture(
        dictionary: """
        けいおん /けいおん!;アニメ/
        けいおんぶ /けいおん!/

        """,
        months: ["2026-01": [("けいおん!", 10)]]
    )
    #expect(try build(fixture).kept == [.init(reading: "けいおん", word: "けいおん!", views: 10, months: 1)])
}

@Test func rowsAreSortedByViewsAndTiesKeepFirstAppearance() throws {
    let fixture = try makeFixture(
        dictionary: """
        あああ /語A/
        いいい /語B/
        ううう /語C/
        えええ /語D/

        """,
        months: [
            "2026-01": [("語B", 5), ("語A", 5), ("語C", 1)],
            "2026-02": [("語D", 5), ("語C", 9)]
        ]
    )
    #expect(try build(fixture).kept.map(\.word) == ["語C", "語B", "語A", "語D"])
}

@Test func wordsSharingReadingWithCommonBaseWordAreExcluded() throws {
    let shards: [String: Data] = [
        // ウ で始まる読み: 「ウエスト」の表記は空（読みと同じ）
        "[30A6]0.loudstxt3": makeShard([
            (ruby: "ウエスト", words: [(word: "", value: -11.55), (word: "上衣", value: -20)])
        ]),
        "[30B7]0.loudstxt3": makeShard([
            (ruby: "シュリ", words: [(word: "首里", value: -14)])
        ]),
        "[30B9]0.loudstxt3": makeShard([
            (ruby: "スノーマン", words: [(word: "SnowMan", value: -9), (word: "ＳＮＯＷ　ＭＡＮ", value: -8)])
        ]),
        "[30DF]0.loudstxt3": makeShard([
            (ruby: "ミルク", words: [(word: "牛乳", value: -12), (word: "ミルク", value: -10.5)])
        ]),
        // 別の最初の文字のファイルは読まれても一致しない
        "[30A2]0.loudstxt3": makeShard([
            (ruby: "アイウ", words: [(word: "藍宇", value: -5)])
        ])
    ]
    let fixture = try makeFixture(
        dictionary: """
        うえすと /WEST./
        しゅり /趣里/
        すのーまん /Snow Man/
        みるく /M!LK/

        """,
        months: ["2026-01": [("WEST.", 40), ("趣里", 30), ("Snow_Man", 20), ("M!LK", 10)]],
        shards: shards
    )
    let output = try build(fixture)
    // 趣里: 首里はコストが低い（一般的でない）。Snow Man: 表記ゆれ（SnowMan）は重なりとみなさない
    #expect(output.kept.map(\.word) == ["趣里", "Snow Man"])
    #expect(output.excluded.map(\.row.word) == ["WEST.", "M!LK"])
    #expect(TrendWordListBuilder.excludedTSV(output.excluded) == """
    うえすと\tWEST.\t40\t1\tウエスト\t-11.55
    みるく\tM!LK\t10\t1\tミルク\t-10.50

    """)
    #expect(TrendWordListBuilder.tsv(output.kept) == "しゅり\t趣里\t30\t1\nすのーまん\tSnow Man\t20\t1\n")
}

@Test func keptRowsAreLimitedToMaximumWords() throws {
    var dictionary = ""
    var articles: [(String, Int)] = []
    for index in 0..<(TrendWordListBuilder.maximumWords + 10) {
        dictionary += "とれんど /トレンド\(index)/\n"
        articles.append(("トレンド\(index)", 100_000 - index))
    }
    let fixture = try makeFixture(dictionary: dictionary, months: ["2026-01": articles])
    let output = try build(fixture)
    #expect(output.kept.count == TrendWordListBuilder.maximumWords)
    #expect(output.kept.last?.word == "トレンド4999")
}

@Test func spellingKeyIgnoresSpacingCaseAndWidth() {
    #expect(TrendWordListBuilder.spellingKey("Snow Man") == TrendWordListBuilder.spellingKey("SnowMan"))
    #expect(TrendWordListBuilder.spellingKey("ＳＮＯＷ　ＭＡＮ") == TrendWordListBuilder.spellingKey("snow-man"))
    #expect(TrendWordListBuilder.spellingKey("Straße") == TrendWordListBuilder.spellingKey("STRASSE"))
    #expect(TrendWordListBuilder.spellingKey("M!LK") != TrendWordListBuilder.spellingKey("ミルク"))
}

@Test func invalidPageviewsFileFails() throws {
    let fixture = try makeFixture(dictionary: "", months: [:])
    let url = fixture.directoryURL.appendingPathComponent("top-2026-01.json")
    try Data("{}".utf8).write(to: url)
    #expect(throws: TrendWordListBuilder.BuildError.self) {
        try TrendWordListBuilder.build(readingDictionaryURL: fixture.dictionaryURL, pageviewURLs: [url], loudsDirectoryURL: fixture.loudsURL)
    }
}
