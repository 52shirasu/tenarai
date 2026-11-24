import Foundation
import Core
import LearningCore
import KanaKanjiConverterModuleWithDefaultDictionary

final class ConverterSession: SegmentManagerDelegate {
    static let conversionContextLength = 200
    static let replaceSuggestionContextLength = 100

    let manager: SegmentsManager
    let conversionSessionID: KanaKanjiConverter.ConversionSessionID
    var inputState: InputState = .none
    var shiftStartedLatinComposition = false
    var inputLanguage: InputLanguage = .japanese
    var lastHandledKeyEventID: UInt64?
    var lastKeyEventResponse: ConverterServerResponse?
    private var context = ConverterTextContext()
    private var compactLeft: String?
    private var compactRight: String?
    var config = ConverterSessionConfig(
        aiBackendPreference: .off,
        openAIModelName: Config.OpenAiModelName.default,
        openAIEndpoint: Config.OpenAiApiEndpoint.default,
        openAIAPIKey: .init(""),
        includeContextInAITransform: true
    )
    var replaceSuggestions: [Candidate] = []
    var replaceSuggestionSelectionIndex: Int?

    init(
        manager: SegmentsManager,
        conversionSessionID: KanaKanjiConverter.ConversionSessionID
    ) {
        self.manager = manager
        self.conversionSessionID = conversionSessionID
        self.manager.delegate = self
    }

    func setContext(_ context: ConverterTextContext) {
        guard self.context != context else { return }
        self.context = context
        func compact(_ text: String?, left: Bool) -> String? {
            guard let text else { return nil }
            return LocalExtractor.compactContext(text, left: left, limit: Self.conversionContextLength)
        }
        compactLeft = compact(context.leftSideContext, left: true)
        compactRight = compact(context.rightSideContext, left: false)
    }

    /// A short sentence in the user's usual tone, used as left context only when the
    /// field has no text at all. Zenzai follows tone from context but not from the
    /// profile/style conditions, so this is how a learned tone reaches it.
    var toneExample: String = ""
    /// Isolated experiments only: a fixed tone example instead of the learned one.
    static let toneExampleOverride: String? = ProcessInfo.processInfo.environment["TENARAI_TEST_ROOT"] != nil
        ? ProcessInfo.processInfo.environment["TENARAI_TEST_TONE_EXAMPLE"] : nil
    /// Bundle identifier of the client app, from the activation.
    var appIdentifier: String?

    func getLeftSideContext(maxCount: Int) -> String? {
        guard let leftSideContext = compactLeft, !leftSideContext.isEmpty else {
            if !toneExample.isEmpty, (compactRight ?? "").isEmpty {
                return String(toneExample.suffix(maxCount))
            }
            return compactLeft
        }
        return String(leftSideContext.suffix(maxCount))
    }

    func getRightSideContext(maxCount: Int) -> String? {
        guard let rightSideContext = compactRight else {
            return nil
        }
        return String(rightSideContext.prefix(maxCount))
    }

    /// The field's own compact context (no tone example), for matching learned items.
    var compactFieldContext: String {
        (compactLeft ?? "") + (compactRight ?? "")
    }

    func conversionLeftSideContext() -> String? {
        getLeftSideContext(maxCount: Self.conversionContextLength)
    }

    func replaceSuggestionPromptContext() -> String {
        let leftSideContext = getLeftSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        let rightSideContext = getRightSideContext(maxCount: Self.replaceSuggestionContextLength) ?? ""
        guard !leftSideContext.isEmpty || !rightSideContext.isEmpty else {
            return ""
        }
        return [
            leftSideContext.isEmpty ? nil : "Text before: ...\(leftSideContext)",
            rightSideContext.isEmpty ? nil : "Text after: \(rightSideContext)..."
        ]
        .compactMap(\.self)
        .joined(separator: "\n")
    }

    func clearReplaceSuggestions() {
        self.replaceSuggestions = []
        self.replaceSuggestionSelectionIndex = nil
    }

    func selectReplaceSuggestion(at index: Int) {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = min(max(0, index), replaceSuggestions.count - 1)
    }

    func selectNextReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        replaceSuggestionSelectionIndex = ((replaceSuggestionSelectionIndex ?? -1) + 1) % replaceSuggestions.count
    }

    func selectPreviousReplaceSuggestion() {
        guard !replaceSuggestions.isEmpty else {
            replaceSuggestionSelectionIndex = nil
            return
        }
        let current = replaceSuggestionSelectionIndex ?? 0
        replaceSuggestionSelectionIndex = (current - 1 + replaceSuggestions.count) % replaceSuggestions.count
    }

    var selectedReplaceSuggestion: Candidate? {
        guard let replaceSuggestionSelectionIndex,
              replaceSuggestions.indices.contains(replaceSuggestionSelectionIndex) else {
            return nil
        }
        return replaceSuggestions[replaceSuggestionSelectionIndex]
    }
}
