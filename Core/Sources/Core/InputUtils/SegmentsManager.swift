import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    // Bundled, immutable data. Rebuilding this on every key repeatedly parses the
    // entire emoji dictionary; no user input or learned candidates belong here.
    static let bundledTextReplacer = TextReplacer.withDefaultEmojiDictionary()

    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        public init(useZenzai: Bool, resourcesDirectoryURL: URL? = nil) {
            self.useZenzai = useZenzai
            self.resourcesDirectoryURL = resourcesDirectoryURL
        }

        var useZenzai: Bool = true
        var resourcesDirectoryURL: URL?
    }

    public var learnedLatinWords: [String] = []
    public var onExplicitLatinCommit: (@MainActor (String) -> Void)?
    private var explicitlySelectedLatin = false
    public var learnedProfile: String = ""
    /// Shift-started Latin input stays literal until an explicit candidate request.
    public var defersLatinConversion = false

    public weak var delegate: (any SegmentManagerDelegate)?
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value && !defersLatinConversion
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    /// Personal n-gram model for Zenzai, when one has been trained and the level is not off.
    /// Looked up per request: a rebuilt model lives at a new path and is picked up at once.
    private func currentPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        let alpha = self.evaluationAlpha ?? Self.personalizationAlphaOverride ?? self.zenzaiPersonalizationLevel.alpha
        guard alpha > 0,
              let personal = PersonalLanguageModelStore.shared.currentModelPrefix(),
              let base = PersonalLanguageModelStore.baseModelPrefix(resources: self.resourcesDirectoryURL) else {
            return nil
        }
        return .init(baseNgramLanguageModel: base, personalNgramLanguageModel: personal, alpha: alpha)
    }

    /// Isolated experiments only: force the personalization strength.
    static let personalizationAlphaOverride: Float? = {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TENARAI_TEST_ROOT"] != nil, let raw = environment["TENARAI_TEST_P13N_ALPHA"] else { return nil }
        return Float(raw)
    }()

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    private enum ContextLength {
        static let conversion = 200
    }

    /// Characters of left/right context given to Zenzai (the compacted context is
    /// at most `ContextLength.conversion`). Isolated tests may override it.
    static let zenzaiContextLength: Int = {
        let environment = ProcessInfo.processInfo.environment
        if environment["TENARAI_TEST_ROOT"] != nil,
           let raw = environment["TENARAI_TEST_CONTEXT_LENGTH"], let value = Int(raw), value > 0 {
            return value
        }
        return 200
    }()

    public func appendDebugMessage(_ string: String) {
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool
    ) -> ConvertRequestOptions.ZenzaiMode {
        guard self.context.useZenzai, let verifiedModel = LocalInferenceSecurity.approvedModelURL else { return .off }
        return .on(
            weight: verifiedModel,
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.currentPersonalizationMode(),
            versionDependentMode: .v3(
                .init(
                    profile: self.learnedProfile,
                    leftSideContext: leftSideContext,
                    rightSideContext: rightSideContext,
                    // Without a limit the prompt builder keeps only 40 characters on each
                    // side, dropping the summary of the farther text in the field.
                    maxLeftSideContextLength: Self.zenzaiContextLength,
                    maxRightSideContextLength: Self.zenzaiContextLength,
                    enableAlignmentSeparator: true,
                    )
            )
        )
    }

    private var resourcesDirectoryURL: URL {
        if let resourcesDirectoryURL = self.context.resourcesDirectoryURL {
            return resourcesDirectoryURL
        }
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        rightSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: self.effectiveLearningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            textReplacer: Self.bundledTextReplacer,
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates
            ),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    public func reloadUserDictionary() {
        self.kanaKanjiConverter.updateUserDictionaryURL(
            CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: self.azooKeyMemoryDir),
            forceReload: true
        )
    }

    @MainActor
    public func resetLearningData() {
        self.kanaKanjiConverter.resetMemory()
    }

    @MainActor
    public func deactivate(flushLearningData: Bool = true) {
        self.kanaKanjiConverter.stopComposition()
        if flushLearningData {
            self.kanaKanjiConverter.commitUpdateLearningData()
        }
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.defersLatinConversion = false
        explicitlySelectedLatin = false
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    /// Enter confirms the reading: a final single "n" still waiting for the next key
    /// means ん, as in standard IMEs. Without this, "henkan" + Enter committed "変化n".
    /// Latin (direct) input such as "Japan" is left untouched.
    @MainActor
    public func finishPendingRomajiN(inputStyle: InputStyle) {
        guard inputStyle != .direct, !self.defersLatinConversion,
              self.composingText.isAtEndIndex,
              self.composingText.convertTarget.count > 1,
              self.composingText.convertTarget.last == "n",
              self.composingText.convertTarget.unicodeScalars.contains(where: { !$0.isASCII }) else {
            return
        }
        self.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: false)
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        self.delegate?.getLeftSideContext(maxCount: maxCount).map {
            var last = $0.suffix(maxCount)
            // 前方の空白を削除する
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    public func getCleanRightSideContext(maxCount: Int) -> String? {
        self.delegate?.getRightSideContext(maxCount: maxCount).map {
            var first = $0.prefix(maxCount)
            // 後方の空白を削除する
            while first.last?.isWhitespace ?? false {
                first = first.dropLast()
            }
            return String(first)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(
        requestRichCandidates: Bool = false,
        forcedLeftSideContext: String? = nil,
        forcedRightSideContext: String? = nil
    ) {
        if defersLatinConversion && !requestRichCandidates {
            explicitlySelectedLatin = false
            self.rawCandidates = nil
            self.selectionIndex = nil
            self.shouldShowCandidateWindow = false
            self.resetAdditionalCandidates()
            return
        }
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.kanaKanjiConverter.stopComposition()
            return
        }
        self.kanaKanjiConverter.importDynamicUserDictionary([], shortcuts: Self.dateTimeShortcuts)

        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        let rightSideContext = forcedRightSideContext ?? self.getCleanRightSideContext(maxCount: ContextLength.conversion)
        var result = self.kanaKanjiConverter.requestCandidates(
            self.composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: rightSideContext,
                requestRichCandidates: requestRichCandidates,
                requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                requireEnglishPrediction: defersLatinConversion ? .autoMix : (Config.DebugPredictiveTyping().value ? .manualMix : .disabled)
            )
        )
        // Expand dictionary coverage when the user opens candidates, not every keystroke.
        if requestRichCandidates && self.context.useZenzai {
            var dictionaryOptions = options(leftSideContext: nil, rightSideContext: nil,
                requestRichCandidates: false, requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled)
            dictionaryOptions.zenzaiMode = .off
            dictionaryOptions.N_best = 40
            let extra = self.kanaKanjiConverter.requestCandidates(self.composingText, options: dictionaryOptions)
            var seen = Set(result.mainResults.map(\.text))
            result.mainResults += extra.mainResults.filter { seen.insert($0.text).inserted }.prefix(16)
            var seenClauses = Set(result.firstClauseResults.map(\.text))
            result.firstClauseResults += extra.firstClauseResults.filter {
                $0.rubyCount >= min(2, self.composingText.convertTarget.count) && seenClauses.insert($0.text).inserted
            }.prefix(16)
        }
        if defersLatinConversion {
            let input = self.composingText.prefixToCursorPosition().convertTarget
            let personal = Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items
                + learnedLatinWords.map { Config.UserDictionaryEntry(word: $0, reading: "") }
            let english = LatinConversionCandidates.words(for: input, personal: personal).map { word in
                self.getModifiedRomanCandidate(inputState: .selecting) { _ in word }
            }
            var seen = Set<String>()
            result.mainResults = (english + result.mainResults.filter {
                self.composingText.isWholeComposingText(composingCount: $0.composingCount)
            }).filter { seen.insert($0.text).inserted }
            // A single English word must not select just its first letter by default.
            result.firstClauseResults = result.mainResults
        }
        if requestRichCandidates && !defersLatinConversion {
            let input = self.composingText.prefixToCursorPosition()
            let raw = input.input.map(\.piece).inputString(preferIntention: false)
            let personal = Config.UserDictionary().value.items + Config.SystemUserDictionary().value.items
            let dateTimeSuggestions = DateTimeCandidates.suggestions(reading: input.convertTarget)
            // Promote existing date/time spellings too: otherwise a duplicate can stay
            // below the visible page while only newly generated formats appear near the top.
            let promotedTexts = Set(dateTimeSuggestions)
            let originalFirst = result.mainResults.first
            result.mainResults.removeAll { promotedTexts.contains($0.text) }
            if let originalFirst, promotedTexts.contains(originalFirst.text) {
                result.mainResults.insert(originalFirst, at: 0)
            }
            let suggestions = dateTimeSuggestions
                + JapaneseTypoCandidates.suggestions(raw: raw, reading: input.convertTarget, personal: personal)
            let extra = suggestions.filter { text in !result.mainResults.contains { $0.text == text } }.map { text in
                // Use the original input count: a repaired reading has a different length.
                Candidate(text: text, value: -1, composingCount: .inputCount(input.input.count),
                          lastMid: MIDData.一般.mid, data: [])
            }
            result.mainResults.insert(contentsOf: extra, at: min(1, result.mainResults.count))
            if !suggestions.isEmpty && !result.mainResults.contains(where: { $0.text == input.convertTarget }) {
                result.mainResults.append(Candidate(text: input.convertTarget, value: -1,
                    composingCount: .inputCount(input.input.count), lastMid: MIDData.一般.mid, data: []))
            }
            // A one-edit miss of a curated fixed phrase is never meant literally, and
            // splitting it into clauses only exposes the typo ("おはよう｜gざいます").
            // Offer the corrected whole phrase first; personal-word matches stay second.
            let phraseCorrections = Set(JapaneseTypoCandidates.phraseCorrections(raw: raw, reading: input.convertTarget))
            if !phraseCorrections.isEmpty, self.composingText.isAtEndIndex {
                let corrections = result.mainResults.filter { phraseCorrections.contains($0.text) }
                result.mainResults.removeAll { phraseCorrections.contains($0.text) }
                result.mainResults.insert(contentsOf: corrections, at: 0)
                result.firstClauseResults.insert(contentsOf: corrections, at: 0)
            }
        }
        self.rawCandidates = result
    }

    /// 日付・時刻変換を事前に入れておく。日時はテンプレートで、変換時に展開されるため不変。
    private static let dateTimeShortcuts: [DicdataElement] =
        [
            ("M/d", -18, DateTemplateLiteral.CalendarType.western),
            ("yyyy/MM/dd", -18.1, .western),
            ("yyyy-MM-dd", -18.2, .western),
            ("M月d日（E）", -18.3, .western),
            ("yyyy年M月d日", -18.4, .western),
            ("Gyyyy年M月d日", -18.5, .japanese),
            ("E曜日", -18.6, .western)
        ].flatMap { (format, value: PValue, type) in
            [
                .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
            ]
        } + [
            // 月
            .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
            // 年
            .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
            .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
            // 時刻
            .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
            .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
            .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
        ]

    /// Called with (reading in katakana, committed text, left context) for each committed
    /// conversion that may be learned; used to measure the personal language model.
    public var onLearnableCommit: ((String, String, String) -> Void)?
    /// Called when the user committed a row other than the first of the candidate list:
    /// (whole reading, first row, committed text, its reading in katakana, left context, row).
    public var onCorrection: ((String, String, String, String, String, Int) -> Void)?
    /// Measurement only: personalization strength for the next requests.
    private var evaluationAlpha: Float?

    /// The top conversion of `reading` with the given personalization strength. Used to
    /// measure the personal model on the user's own commits; must run inside its own
    /// converter session, and never learns.
    @MainActor public func evaluationTopCandidate(reading: String, leftSideContext: String, alpha: Float) -> String? {
        let hiragana = reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading
        var text = ComposingText()
        text.insertAtCursorPosition(hiragana, inputStyle: .direct)
        evaluationAlpha = alpha
        defer { evaluationAlpha = nil }
        let options = options(leftSideContext: leftSideContext, rightSideContext: nil, requestRichCandidates: false,
                              requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled)
        let result = kanaKanjiConverter.requestCandidates(text, options: options)
        kanaKanjiConverter.stopComposition()
        return result.mainResults.first?.text
    }

    /// Set for apps excluded from learning: learned words are still used, nothing new is stored.
    public var suppressesLearning = false

    var effectiveLearningType: LearningType {
        let configured = Config.Learning().value.learningType
        return suppressesLearning && configured == .inputAndOutput ? .onlyOutput : configured
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// Opens the candidate list for the current composition (Space, ↓). The list always
    /// starts at its first row: a row index left from an earlier list (closed with
    /// Escape, or committed) made the new list open in the middle (2026-11-19).
    ///
    /// The first row is the best result of the richer search, not necessarily the live
    /// conversion on screen: Space is pressed mostly when that conversion is wrong, and
    /// keeping it first cost a second Space to reach the right one.
    @MainActor public func openCandidateList(inputStyle: InputStyle) {
        self.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: true)
        self.requestResettingSelection()
        self.update(requestRichCandidates: true)
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        if defersLatinConversion && explicitlySelectedLatin && LatinConversionCandidates.validName(candidate.text) {
            if !suppressesLearning { onExplicitLatinCommit?(candidate.text) }
            explicitlySelectedLatin = false
        }
        self.kanaKanjiConverter.setCompletedData(candidate)
        if !suppressesLearning {
            self.kanaKanjiConverter.updateLearningData(candidate)
            if Config.Learning().value == .inputAndOutput {
                onLearnableCommit?(candidate.data.map(\.ruby).joined(), candidate.text, leftSideContext)
                if let selectionIndex, selectionIndex > 0, let shown = self.candidates?.first, shown.text != candidate.text {
                    onCorrection?(self.composingText.convertTarget, shown.text, candidate.text,
                                  candidate.data.map(\.ruby).joined(), leftSideContext, selectionIndex)
                }
            }
        }
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        // The selection belongs to the candidate list that was just used. Without this
        // reset after a whole commit, the next composition opened its list at the old
        // row and Enter committed that row ("よう" -> 3rd row again, 2026-11-19).
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.didExperienceSegmentEdition = false
        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.shouldShowCandidateWindow = true
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        } else {
            // Nothing is left: start the next composition from a clean text. After a
            // segment edit the emptied text kept its cursor position, and the next key
            // aborted the helper (negative prefix length, found by the Nov 19 sprint).
            self.composingText.stopComposition()
            self.rawCandidates = nil
            self.shouldShowCandidateWindow = false
            self.resetAdditionalCandidates()
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        if !visible { explicitlySelectedLatin = false }
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        if defersLatinConversion { explicitlySelectedLatin = true }
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        if defersLatinConversion { explicitlySelectedLatin = true }
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if defersLatinConversion { explicitlySelectedLatin = true }
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        explicitlySelectedLatin = false
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if defersLatinConversion { return .hidden }
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public init(text: [Element], selectionRange: NSRange) {
            self.text = text
            self.selectionRange = selectionRange
        }

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    /// - Parameter learn: `false` for commits the user did not ask for, such as the
    ///   focus-change commit IMK requests while a composition is still being typed.
    @MainActor
    public func commitMarkedText(inputState: InputState, learn: Bool = true) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        // In selecting, the focused text is a candidate the user explicitly chose.
        if learn,
           inputState == .selecting || Self.shouldLearnImplicitCommit(text: text, reading: self.composingText.convertTarget),
           let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    /// Whether committing the marked text without choosing a candidate should teach
    /// the converter. Unconverted kana (shown after Backspace or with live conversion
    /// off) and text with pending romaji are not conversions the user picked; learning
    /// them made raw readings and fragments such as "おk" outrank real conversions.
    static func shouldLearnImplicitCommit(text: String, reading: String) -> Bool {
        guard !text.isEmpty else { return false }
        if text == reading || text == reading.toKatakana() {
            return false
        }
        if let last = reading.unicodeScalars.last, last.isASCII, CharacterSet.letters.contains(last),
           reading.unicodeScalars.contains(where: { !$0.isASCII }) {
            return false
        }
        return true
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard let candidate = self.firstPredictionCandidate(),
              let prediction = Self.makePredictionCandidate(currentTarget: self.composingText.convertTarget, candidate: candidate) else {
            return []
        }
        return [prediction]
    }

    private func firstPredictionCandidate() -> Candidate? {
        guard Config.DebugPredictiveTyping().value else {
            return nil
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return nil
        }

        guard let rawCandidates else {
            return nil
        }

        return rawCandidates.predictionResults.first {
            Self.makePredictionCandidate(currentTarget: target, candidate: $0) != nil
        }
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidate: Candidate
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidate.data.map(\.ruby).joined().toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: candidate.text, appendText: appendText, deleteCount: deleteCount)
    }

    @MainActor
    public func acceptPredictionCandidate() {
        if let prediction = self.requestTypoCorrectionPredictionCandidates().first {
            self.acceptTypoCorrectionPredictionCandidate(prediction)
        } else if let candidate = self.firstPredictionCandidate() {
            self.acceptPredictionCandidate(candidate)
        }
    }

    @MainActor
    func acceptPredictionCandidate(_ candidate: Candidate) {
        guard self.kanaKanjiConverter.acceptPredictionCandidate(candidate, composingText: &self.composingText) else {
            return
        }
        self.lastInputStyle = .direct
        self.lastOperation = .insert
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    func acceptTypoCorrectionPredictionCandidate(_ prediction: PredictionCandidate) {
        if prediction.deleteCount > 0 {
            self.deleteBackwardFromCursorPosition(count: prediction.deleteCount)
        }
        if !prediction.appendText.isEmpty {
            self.insertAtCursorPosition(prediction.appendText, inputStyle: .direct)
        }
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: ContextLength.conversion) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                rightSideContext: nil,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: ContextLength.conversion)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは常にひらがなを示す
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    func getRightSideContext(maxCount: Int) -> String?
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
