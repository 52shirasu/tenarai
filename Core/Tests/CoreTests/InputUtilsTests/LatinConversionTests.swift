import Foundation
import Testing
import KanaKanjiConverterModuleWithDefaultDictionary
@testable import Core

@Test func latinCandidateOrderKeepsOriginalAndRejectsUnrelatedGuesses() {
    let iphone = LatinConversionCandidates.ordered(input: "Iphone", completions: ["iPhone", "iPhones"], guesses: ["iPhone", "Phone"])
    #expect(iphone.prefix(2).elementsEqual(["iPhone", "Iphone"]))
    #expect(iphone.contains("アイフォン"))
    #expect(iphone.contains("iPhones"))
    #expect(!iphone.contains("Phone"))
    let docker = LatinConversionCandidates.ordered(input: "Docker", completions: [], guesses: ["Locker", "Docket"])
    #expect(docker.first == "Docker")
    #expect(!docker.contains("Locker"))
}

@MainActor @Test func deferredLatinTypingSelectionAndResume() {
    let manager = SegmentsManager(kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: FileManager.default.temporaryDirectory, containerURL: nil,
        context: .init(useZenzai: false))
    manager.defersLatinConversion = true
    manager.insertAtCursorPosition("Iphone", inputStyle: .direct)
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "Iphone")
    if case .hidden = manager.getCurrentCandidateWindow(inputState: .composing) {} else { Issue.record("Candidates visible during Latin typing") }
    manager.update(requestRichCandidates: true)
    guard case .selecting(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .selecting) else {
        Issue.record("Space conversion did not generate a list"); return
    }
    #expect(candidates.contains { $0.text == "Iphone" })
    #expect(candidates.contains { $0.text == "アイフォン" })
    manager.deleteBackwardFromCursorPosition()
    #expect(manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined() == "Iphon")
    if case .hidden = manager.getCurrentCandidateWindow(inputState: .composing) {} else { Issue.record("Candidates visible during Latin typing") }
    manager.stopComposition()
    #expect(!manager.defersLatinConversion)
}

@Test func bundledEnglishReadingsUsePronunciationAndHandleUnknownWords() {
    #expect(LatinConversionCandidates.katakana(for: "Iphone").contains("アイフォン"))
    #expect(LatinConversionCandidates.katakana(for: "MAC").contains("マック"))
    #expect(LatinConversionCandidates.katakana(for: "Docker").contains("ドッカー"))
    #expect(LatinConversionCandidates.katakana(for: "zzunknownword").isEmpty)
}

@Test func closeTypoSuggestionsPreserveOriginalAndAddPronunciation() {
    let iphone = LatinConversionCandidates.ordered(input: "Iphnoe", completions: [], guesses: ["iPhone", "Siphon"])
    #expect(iphone.prefix(3).elementsEqual(["Iphnoe", "iPhone", "アイフォン"]))
    #expect(!iphone.contains("Siphon"))
    let docker = LatinConversionCandidates.ordered(input: "Dokcer", completions: [], guesses: ["Docker", "Locker"])
    #expect(docker.contains("Docker"))
    #expect(docker.contains("ドッカー"))
    #expect(!docker.contains("Locker"))
    #expect(LatinConversionCandidates.ordered(input: "Docker", completions: [], guesses: ["Locker", "Dockers"]).first == "Docker")
    #expect(!LatinConversionCandidates.ordered(input: "Docker", completions: [], guesses: ["Locker", "Dockers"]).contains("Dockers"))
}
