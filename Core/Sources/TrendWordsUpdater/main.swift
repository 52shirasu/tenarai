import Foundation
import os
import TrendWords

// 流行語の一覧（trend/trend.tsv）を作り直す。
//
//   TrendWordsUpdater [--force] [--louds DIR]
//       公開ファイルを取得して一覧を作り直す。利用者の情報は送らない
//   TrendWordsUpdater --from-directory DIR --louds DIR --output FILE [--excluded FILE]
//       通信せず、取得済みのファイル（SKK-JISYO.jawiki、top-*.json）から一覧を作るだけ
//
// 結果を1行、標準出力に出す。終了コードは 更新・スキップ 0、失敗 1。

let logger = Logger(subsystem: "local.tenarai.tenarai", category: "trend")

struct Arguments {
    var force = false
    var loudsDirectory: String?
    var fromDirectory: String?
    var output: String?
    var excluded: String?
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: TrendWordsUpdater [--force] [--louds DIR]
           TrendWordsUpdater --from-directory DIR --louds DIR --output FILE [--excluded FILE]

    """.utf8))
    exit(2)
}

func parseArguments(_ arguments: [String]) -> Arguments {
    var result = Arguments()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--force":
            result.force = true
        case "--louds":
            guard let value = iterator.next() else { usage() }
            result.loudsDirectory = value
        case "--from-directory":
            guard let value = iterator.next() else { usage() }
            result.fromDirectory = value
        case "--output":
            guard let value = iterator.next() else { usage() }
            result.output = value
        case "--excluded":
            guard let value = iterator.next() else { usage() }
            result.excluded = value
        default:
            usage()
        }
    }
    return result
}

/// `<実行ファイルのディレクトリ>/../ConverterServer/` の下の `*.bundle` から基本辞書を探す
func findLoudsDirectory() -> URL? {
    guard let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        return nil
    }
    let serverDirectoryURL = executableURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ConverterServer", isDirectory: true)
    let fileManager = FileManager.default
    guard let bundles = try? fileManager.contentsOfDirectory(at: serverDirectoryURL, includingPropertiesForKeys: nil) else {
        return nil
    }
    for bundleURL in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where bundleURL.pathExtension == "bundle" {
        guard let enumerator = fileManager.enumerator(at: bundleURL, includingPropertiesForKeys: nil) else {
            continue
        }
        for case let url as URL in enumerator where url.lastPathComponent == "charID.chid" {
            let directoryURL = url.deletingLastPathComponent()
            if directoryURL.lastPathComponent == "louds", directoryURL.deletingLastPathComponent().lastPathComponent == "Dictionary" {
                return directoryURL
            }
        }
    }
    return nil
}

func finish(_ line: String, success: Bool) -> Never {
    print(line)
    if success {
        logger.info("\(line, privacy: .public)")
    } else {
        logger.error("\(line, privacy: .public)")
    }
    exit(success ? 0 : 1)
}

let arguments = parseArguments(Array(CommandLine.arguments.dropFirst()))

if let fromDirectory = arguments.fromDirectory {
    // 通信せず、取得済みのファイルから作るだけ。データの場所や設定には触れない
    guard let loudsDirectory = arguments.loudsDirectory, let output = arguments.output, !arguments.force else {
        usage()
    }
    let directoryURL = URL(fileURLWithPath: fromDirectory, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
    let pageviewURLs = names
        .filter { $0.hasPrefix("top-") && $0.hasSuffix(".json") }
        .map { directoryURL.appendingPathComponent($0, isDirectory: false) }
    do {
        let result = try TrendWordListBuilder.build(
            readingDictionaryURL: directoryURL.appendingPathComponent("SKK-JISYO.jawiki", isDirectory: false),
            pageviewURLs: pageviewURLs,
            loudsDirectoryURL: URL(fileURLWithPath: loudsDirectory, isDirectory: true)
        )
        try Data(TrendWordListBuilder.tsv(result.kept).utf8).write(to: URL(fileURLWithPath: output))
        if let excluded = arguments.excluded {
            try Data(TrendWordListBuilder.excludedTSV(result.excluded).utf8).write(to: URL(fileURLWithPath: excluded))
        }
        let skipped = result.skipped.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        finish("built articles=\(result.articleCount) words=\(result.kept.count) excluded=\(result.excluded.count) skipped=\(skipped)", success: true)
    } catch {
        finish("failed error=\(error)", success: false)
    }
} else {
    guard arguments.output == nil, arguments.excluded == nil else {
        usage()
    }
    let loudsDirectoryURL = arguments.loudsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? findLoudsDirectory()
    guard let loudsDirectoryURL else {
        finish("failed words=0 excluded=0 error=base dictionary not found", success: false)
    }
    let result = await TrendWordsUpdate.run(options: .init(force: arguments.force, loudsDirectoryURL: loudsDirectoryURL))
    finish(result.summary, success: result.outcome != .failed)
}
