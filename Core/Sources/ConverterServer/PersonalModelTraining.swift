import Core
import Foundation

/// Feeds committed typing into the personal language model and rebuilds it when idle.
/// Training runs at background priority, never on the key-event path.
enum PersonalModelTraining {
    /// Rebuild after this many new lines, once input has been idle for `idleDelay`.
    static let linesPerRebuild = 20
    static let idleDelay: Duration = {
        // Isolated tests only: shorten the idle wait.
        let environment = ProcessInfo.processInfo.environment
        if environment["TENARAI_TEST_ROOT"] != nil, let raw = environment["TENARAI_TEST_P13N_IDLE_SECONDS"], let seconds = Int(raw) {
            return .seconds(seconds)
        }
        return .seconds(60)
    }()
    private static let state = State()

    private actor State {
        var scheduled: Task<Void, Never>?
        var training = false

        func schedule(after delay: Duration) {
            scheduled?.cancel()
            scheduled = Task(priority: .background) {
                do { try await Task.sleep(for: delay) } catch { return }
                await self.trainNow()
            }
        }

        func trainNow() async {
            guard !training else { return }
            training = true
            defer { training = false }
            // Measure the current model on clauses committed since it was built (it has not
            // seen them), then rebuild with them.
            await PersonalModelTraining.evaluatePendingPairs()
            await Task.detached(priority: .background) { PersonalLanguageModelStore.shared.train() }.value
        }

        func cancel() {
            scheduled?.cancel()
            scheduled = nil
        }
    }

    /// At startup: rebuild if text was added since the last build (e.g. before a restart).
    static func prepare() {
        Task.detached(priority: .background) {
            let store = PersonalLanguageModelStore.shared
            guard Config.Learning().value != .nothing else { return }
            if store.corpusIsNewerThanModel {
                await state.trainNow()
            }
        }
    }

    /// Commits are often clause fragments (「誤変換が」「多い」). A model built from
    /// fragments behaves like the word list that lowered accuracy, so consecutive commits
    /// in the same app are joined into one line until a sentence ends or input pauses.
    private static let sentenceBuffer = SentenceBuffer()

    static func record(_ text: String, app: String?) {
        Task { await sentenceBuffer.add(text, app: app ?? "") }
    }

    fileprivate static func store(line: String) {
        let store = PersonalLanguageModelStore.shared
        store.append(line)
        if store.pendingLineCount >= linesPerRebuild {
            Task { await state.schedule(after: idleDelay) }
        }
    }

    private actor SentenceBuffer {
        private var pending: [String: String] = [:]
        private var flushTasks: [String: Task<Void, Never>] = [:]
        /// Fragments of one sentence arrive within a second or two; a longer gap usually
        /// means the message was sent and a new one begins.
        static let pause: Duration = {
            let environment = ProcessInfo.processInfo.environment
            if environment["TENARAI_TEST_ROOT"] != nil, let raw = environment["TENARAI_TEST_P13N_PAUSE_MS"], let ms = Int(raw) {
                return .milliseconds(ms)
            }
            return .seconds(6)
        }()
        static let maximumLength = 300

        func add(_ text: String, app: String) {
            var buffer = (pending[app] ?? "") + text
            // Sentence ends and newlines close a line; keep any trailing partial sentence.
            while let end = buffer.firstIndex(where: { "。！？!?\n".contains($0) }) {
                PersonalModelTraining.store(line: String(buffer[...end]))
                buffer = String(buffer[buffer.index(after: end)...])
            }
            if buffer.count >= Self.maximumLength {
                PersonalModelTraining.store(line: buffer)
                buffer = ""
            }
            pending[app] = buffer.isEmpty ? nil : buffer
            flushTasks[app]?.cancel()
            guard !buffer.isEmpty else { return }
            flushTasks[app] = Task {
                do { try await Task.sleep(for: Self.pause) } catch { return }
                self.flush(app)
            }
        }

        func flush(_ app: String) {
            if let buffer = pending.removeValue(forKey: app) {
                PersonalModelTraining.store(line: buffer)
            }
        }

        func clear() {
            flushTasks.values.forEach { $0.cancel() }
            flushTasks.removeAll()
            pending.removeAll()
        }
    }

    /// Converts each pair at the given strength and returns the top candidate, or nil when
    /// the user started typing (the measurement then stops). Set by the server.
    nonisolated(unsafe) static var evaluator: (@MainActor (PersonalLanguageModelStore.EvaluationPair, Float) async -> String??)?
    /// Fewer clauses than this say nothing; they are dropped (the model learns them anyway).
    static let minimumPairsPerEvaluation = 10

    static func recordPair(reading: String, text: String, leftContext: String) {
        // Readings equal to the text (kana left as typed) measure nothing.
        guard reading != text, text.applyingTransform(.hiraganaToKatakana, reverse: false) != reading else { return }
        let pair = PersonalLanguageModelStore.EvaluationPair(reading: reading, text: text, leftContext: leftContext)
        Task.detached(priority: .background) { PersonalLanguageModelStore.shared.appendPair(pair) }
    }

    static func evaluatePendingPairs() async {
        let store = PersonalLanguageModelStore.shared
        let pairs = store.takePairs()
        guard pairs.count >= minimumPairsPerEvaluation, store.currentModelPrefix() != nil,
              let evaluator else { return }
        var matches: [Float: Int] = [:]
        for alpha in PersonalLanguageModelStore.candidateAlphas {
            var count = 0
            for pair in pairs {
                guard let top = await evaluator(pair, alpha) else { return }
                if top == pair.text { count += 1 }
            }
            matches[alpha] = count
        }
        let result = store.record(pairs: pairs.count, matches: matches)
        ConverterServer.log.notice("p13n evaluation: pairs=\(pairs.count) matches=\(matches.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","), privacy: .public) tuned=\(result.tunedAlpha)")
    }

    static func reset() {
        Task { await state.cancel(); await sentenceBuffer.clear() }
        PersonalLanguageModelStore.shared.reset()
    }
}
