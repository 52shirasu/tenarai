import Foundation
import Core
import KanaKanjiConverterModuleWithDefaultDictionary

// Offline maintenance for an azooKey learning-memory directory.
// usage: TenaraiMemoryTool <memory-dir> forget <ruby>=<word> [...]
// Run only while no ConverterServer uses the directory; azooKey forgets by word
// in long-term memory, so every learned reading of each word is removed.
let arguments = CommandLine.arguments
// usage: TenaraiMemoryTool p13n <p13n-dir> [append <text-file>] [train]
if arguments.count >= 3, arguments[1] == "p13n" {
    let store = PersonalLanguageModelStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
    var index = 3
    while index < arguments.count {
        switch arguments[index] {
        case "append":
            let text = (try? String(contentsOfFile: arguments[index + 1], encoding: .utf8)) ?? ""
            print("appended", store.append(text))
            index += 2
        case "train":
            print("trained", store.train(), store.currentModelPrefix() ?? "-")
            index += 1
        default:
            FileHandle.standardError.write("unknown p13n command\n".data(using: .utf8)!)
            exit(64)
        }
    }
    exit(0)
}
guard arguments.count >= 4, arguments[2] == "forget" else {
    FileHandle.standardError.write("usage: TenaraiMemoryTool <memory-dir> forget <ruby>=<word> ...\n".data(using: .utf8)!)
    exit(64)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("memory.louds").path) else {
    FileHandle.standardError.write("not a learning-memory directory\n".data(using: .utf8)!)
    exit(65)
}
let targets: [DicdataElement] = arguments.dropFirst(3).compactMap { pair in
    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return DicdataElement(word: parts[1], ruby: parts[0], cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
}
let converter = KanaKanjiConverter.withDefaultDictionary()
let options = ConvertRequestOptions(
    requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled, keyboardLanguage: .ja_JP,
    learningType: .inputAndOutput, memoryDirectoryURL: directory, sharedContainerURL: directory,
    textReplacer: .empty, specialCandidateProviders: nil, metadata: nil)
var text = ComposingText()
text.insertAtCursorPosition("a", inputStyle: .direct)
// A request applies the learning configuration (memory directory) to the store.
_ = converter.requestCandidates(text, options: options)
converter.forgetMemory(Candidate(text: "", value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: targets))
converter.stopComposition()
print("forgot \(targets.count) word(s)")
