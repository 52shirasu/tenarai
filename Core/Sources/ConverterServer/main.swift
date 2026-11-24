import os
import Core
import Darwin
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

private enum ConverterServerXPC {
    static let machServiceName = ProcessInfo.processInfo.environment["TENARAI_TEST_ROOT"] == nil
        ? "local.tenarai.inputmethod.tenarai.ConverterServer"
        : "local.tenarai.inputmethod.tenarai.Scenario"
}

@objc private protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

final class ConverterServer: NSObject, ConverterServerXPCProtocol, @unchecked Sendable {
    static let log = Logger(subsystem: "local.tenarai.tenarai", category: "server")
    private static let learningDataCommitDelay: TimeInterval = 2

    @MainActor lazy var localLearning = LocalLearningService()
    /// Measurements of the personal model run only while input is idle.
    @MainActor var lastKeyEventDate = Date.distantPast
    @MainActor private var evaluationSession: (id: KanaKanjiConverter.ConversionSessionID, manager: SegmentsManager)?

    private var sessions: [String: ConverterSession] = [:]
    private let kanaKanjiConverter = KanaKanjiConverter.withDefaultDictionary()
    private let learningDataCommitScheduler = DebouncedActionScheduler()

    @MainActor
    func prepareLocalInference() {
        guard LocalInferenceSecurity.approvedModelURL != nil else { return }
        let warmSession = kanaKanjiConverter.createSession()
        let manager = Self.makeSegmentsManager(kanaKanjiConverter: kanaKanjiConverter)
        try? kanaKanjiConverter.withSession(warmSession) {
            manager.insertAtCursorPosition("a", inputStyle: .roman2kana)
            manager.update(requestRichCandidates: false)
        }
        kanaKanjiConverter.removeSession(warmSession)
        // Nothing is committed; synthetic warm-up must not enter learning history.
        PersonalModelTraining.evaluator = { [weak self] pair, alpha in
            guard let self else { return nil }
            return await self.evaluatePersonalModel(pair, alpha: alpha)
        }
        // Isolated comparisons only: the upstream handling of rejected learned words.
        let environment = ProcessInfo.processInfo.environment
        if environment["TENARAI_TEST_ROOT"] != nil, environment["TENARAI_TEST_PERSONAL_PASS_THROUGH"] == "1" {
            ZenzaiTuning.constrainsRejectedPersonalWords = false
        }
        PersonalModelTraining.prepare()
    }

    /// One measured conversion, or nil (outer) to stop because the user is typing.
    @MainActor
    private func evaluatePersonalModel(_ pair: PersonalLanguageModelStore.EvaluationPair, alpha: Float) async -> String?? {
        // Let queued key events run first; each conversion holds the main actor briefly.
        await Task.yield()
        guard Date().timeIntervalSince(lastKeyEventDate) > 5 else { return nil }
        if evaluationSession == nil {
            evaluationSession = (kanaKanjiConverter.createSession(), Self.makeSegmentsManager(kanaKanjiConverter: kanaKanjiConverter))
        }
        guard let (id, manager) = evaluationSession else { return nil }
        let top = try? kanaKanjiConverter.withSession(id) {
            manager.evaluationTopCandidate(reading: pair.reading, leftSideContext: pair.leftContext, alpha: alpha)
        }
        return .some(top ?? nil)
    }

    func openSession(with reply: @escaping @Sendable (String) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let sessionID = UUID().uuidString
                self.createSessionIfNeeded(sessionID)
                reply(sessionID)
            }
        }
    }

    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let session = self.sessions.removeValue(forKey: sessionID)
                if let session {
                    self.kanaKanjiConverter.removeSession(session.conversionSessionID)
                }
                let removed = session != nil
                reply(removed)
            }
        }
    }

    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) {
        reply("ConverterServer: \(message)")
    }

    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {
        guard data.count <= 262_144 else { reply(nil, "Request too large"); return }
        // キー入力の応答はユーザー操作のクリティカルパスなので、システム負荷が高い時も
        // utility/background work より先に実行される優先度で Server actor へ渡す。
        let received = DispatchTime.now().uptimeNanoseconds
        Task(priority: .userInitiated) { @MainActor in
            do {
                let command = try ConverterServerCodec.decodeCommand(from: data)
                let started = DispatchTime.now().uptimeNanoseconds
                let response = try await self.handle(command)
                let finished = DispatchTime.now().uptimeNanoseconds
                // Content-free: only the command kind and timings.
                if finished - received > 500_000_000 {
                    Self.log.notice("slow command \(command.kindName, privacy: .public) wait=\((started - received) / 1_000_000, privacy: .public)ms run=\((finished - started) / 1_000_000, privacy: .public)ms")
                }
                self.learningDataCommitScheduler.postponeIfScheduled(
                    after: Self.learningDataCommitDelay
                )
                reply(try ConverterServerCodec.encode(response), nil)
            } catch {
                self.learningDataCommitScheduler.postponeIfScheduled(
                    after: Self.learningDataCommitDelay
                )
                reply(nil, error.localizedDescription as NSString)
            }
        }
    }

    @MainActor
    private func handle(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
        switch command {
        case .shutdown:
            Self.scheduleShutdown()
            return ConverterServerResponse(snapshot: .empty)
        case .maintenance(let command):
            return try handle(command)
        case .openSession(let sessionID, let command):
            createSessionIfNeeded(sessionID)
            return try await handle(command, sessionID: sessionID)
        case .session(let sessionID, let command):
            return try await handle(command, sessionID: sessionID)
        }
    }

    @MainActor
    private func createSessionIfNeeded(_ sessionID: String) {
        guard sessions[sessionID] == nil else {
            return
        }
        let conversionSessionID = kanaKanjiConverter.createSession()
        sessions[sessionID] = ConverterSession(
            manager: Self.makeSegmentsManager(kanaKanjiConverter: kanaKanjiConverter),
            conversionSessionID: conversionSessionID
        )
        sessions[sessionID]?.manager.onExplicitLatinCommit = { [weak self] word in
            self?.localLearning.observe(word, origin: .typed, selectedLatin: true)
        }
        sessions[sessionID]?.manager.onLearnableCommit = { reading, text, leftContext in
            PersonalModelTraining.recordPair(reading: reading, text: text, leftContext: leftContext)
        }
        sessions[sessionID]?.manager.onCorrection = { reading, shown, chosen, chosenReading, leftContext, index in
            let correction = PersonalLanguageModelStore.Correction(
                reading: reading, shown: shown, chosen: chosen, chosenReading: chosenReading, leftContext: leftContext, index: index)
            Task.detached(priority: .background) { PersonalLanguageModelStore.shared.appendCorrection(correction) }
        }
    }

    @MainActor
    private func handle(_ command: ConverterMaintenanceCommand) throws -> ConverterServerResponse {
        switch command {
        case .synchronizeUserDictionary(let forceExport):
            let memoryDirectoryURL = AppGroup.memoryDirectoryURL()
            if forceExport || CompiledUserDictionaryStore.needsExport(memoryDirectoryURL: memoryDirectoryURL) {
                try CompiledUserDictionaryStore.exportCurrentDictionaries(memoryDirectoryURL: memoryDirectoryURL)
            }
            kanaKanjiConverter.updateUserDictionaryURL(
                CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: memoryDirectoryURL),
                forceReload: true
            )
        case .resetLearningData:
            kanaKanjiConverter.resetMemory()
            PersonalModelTraining.reset()
        case .listLearnedConversions:
            // Recent commits are still in memory; write them so the list is complete.
            kanaKanjiConverter.commitUpdateLearningData()
            return ConverterServerResponse(
                learnedConversions: LearningMemoryReader.conversions(in: AppGroup.memoryDirectoryURL()), snapshot: .empty)
        case .forgetLearnedConversions(let items):
            kanaKanjiConverter.commitUpdateLearningData()
            let elements = items.prefix(1000).map {
                DicdataElement(word: $0.word, ruby: $0.reading, cid: CIDData.一般名詞.cid, mid: MIDData.一般.mid, value: 0)
            }
            if !elements.isEmpty {
                kanaKanjiConverter.forgetMemory(Candidate(text: "", value: 0, composingCount: .surfaceCount(0), lastMid: 0, data: Array(elements)))
            }
            return ConverterServerResponse(
                learnedConversions: LearningMemoryReader.conversions(in: AppGroup.memoryDirectoryURL()), snapshot: .empty)
        }
        return ConverterServerResponse(snapshot: .empty)
    }

    @MainActor
    private func handle(_ command: ConverterSessionCommand, sessionID: String) async throws -> ConverterServerResponse {
        let session = try getSession(sessionID)
        switch command {
        case .learning(let command):
            let values = try await localLearning.handle(command, app: session.appIdentifier)
            return ConverterServerResponse(localTendencies: values, learningFailed: localLearning.failed, snapshot: .empty)
        case .lifecycle(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .settings(let command):
            return try withConverterSession(session) {
                try handle(command, session: session)
            }
        case .updateConfig(let config):
            return try withConverterSession(session) {
                session.config = config
                return makeResponse(for: session, inputState: .none)
            }
        case .handleKeyEvent(let request):
            return try withConverterSession(session) {
                try handleKeyEvent(sessionID: sessionID, request: request)
            }
        case .composition(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .candidate(let command):
            return try withConverterSession(session) {
                handle(command, session: session)
            }
        case .replaceSuggestion(let command):
            return try await handle(command, session: session)
        }
    }

    @MainActor
    private func withConverterSession<Result>(
        _ session: ConverterSession,
        operation: () throws -> Result
    ) throws -> Result {
        try kanaKanjiConverter.withSession(session.conversionSessionID, operation: operation)
    }

    @MainActor
    private func handle(
        _ command: ConverterSessionLifecycleCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .activate:
            session.manager.activate()
            return makeResponse(for: session, inputState: session.inputState)
        case .deactivate:
            // アプリ切替直後のキー入力を、学習データの同期I/Oで塞がない。
            // 共有Converterはプロセス内に残るため、永続化だけ入力のアイドル時まで遅延できる。
            session.manager.deactivate(flushLearningData: false)
            scheduleLearningDataCommit()
            session.inputState = .none
            session.clearReplaceSuggestions()
            return makeResponse(for: session, inputState: session.inputState)
        case .synchronizeInputLanguage(let language):
            session.inputLanguage = language
            if language == .english {
                session.manager.stopJapaneseInput()
            }
            return makeResponse(
                for: session,
                inputState: session.inputState
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterSettingsCommand,
        session: ConverterSession
    ) throws -> ConverterServerResponse {
        switch command {
        case .list(let capabilities):
            return makeResponse(
                for: session,
                inputState: .none,
                settings: Self.makeSettingDescriptors(capabilities: capabilities)
            )
        case .update(let key, let value):
            try Self.updateSetting(key: key, value: value)
            return makeResponse(for: session, inputState: .none)
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCompositionCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .snapshot:
            return makeResponse(for: session, inputState: session.inputState)
        case .stopComposition:
            session.manager.stopComposition()
            session.inputState = .none
            return makeResponse(for: session, inputState: session.inputState)
        case .forgetMemory:
            session.manager.forgetMemory()
            return makeResponse(for: session, inputState: session.inputState)
        case .commit:
            // IMK requests this on focus changes, often mid-typing; it is not a choice.
            let text = session.manager.commitMarkedText(inputState: session.inputState, learn: false)
            let effects: [ConverterClientEffect] = text.isEmpty ? [] : [.insertText(text)]
            session.inputState = .none
            return makeResponse(
                for: session,
                inputState: session.inputState,
                effects: effects,
                responseInputState: ConverterInputState.none
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterCandidateCommand,
        session: ConverterSession
    ) -> ConverterServerResponse {
        switch command {
        case .selectCandidate(let index):
            session.manager.requestSelectingRow(index)
            session.inputState = .selecting
            return makeResponse(for: session, inputState: session.inputState)
        case .submitSelectedCandidate(let context):
            session.setContext(context)
            var effects: [ConverterClientEffect] = []
            submitSelectedCandidate(
                manager: session.manager,
                leftSideContext: session.conversionLeftSideContext(),
                effects: &effects
            )
            let nextInputState: InputState = session.manager.isEmpty ? .none : .previewing
            session.inputState = nextInputState
            return makeResponse(
                for: session,
                inputState: nextInputState,
                effects: effects,
                responseInputState: ConverterInputState(nextInputState)
            )
        }
    }

    @MainActor
    private func handle(
        _ command: ConverterReplaceSuggestionCommand,
        session: ConverterSession
    ) async throws -> ConverterServerResponse {
        switch command {
        case .request(let context):
            session.setContext(context)
            try await requestReplaceSuggestion(session: session)
            return try withConverterSession(session) {
                session.inputState = .replaceSuggestion
                return makeResponse(
                    for: session,
                    inputState: session.inputState,
                    responseInputState: .replaceSuggestion
                )
            }
        case .selectReplaceSuggestionCandidate(let index):
            return try withConverterSession(session) {
                session.selectReplaceSuggestion(at: index)
                session.inputState = .replaceSuggestion
                return makeResponse(
                    for: session,
                    inputState: session.inputState,
                    responseInputState: .replaceSuggestion
                )
            }
        case .submitSelectedReplaceSuggestion:
            return try withConverterSession(session) {
                var effects: [ConverterClientEffect] = []
                let didSubmit = submitSelectedReplaceSuggestion(session: session, effects: &effects)
                let nextInputState: InputState = didSubmit ? .none : .replaceSuggestion
                session.inputState = nextInputState
                return makeResponse(
                    for: session,
                    inputState: nextInputState,
                    effects: effects,
                    responseInputState: ConverterInputState(nextInputState)
                )
            }
        }
    }

    private static func scheduleShutdown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(EXIT_SUCCESS)
        }
    }

    @MainActor
    private func scheduleLearningDataCommit() {
        learningDataCommitScheduler.schedule(after: Self.learningDataCommitDelay) { [weak self] in
            self?.kanaKanjiConverter.commitUpdateLearningData()
        }
    }

    @MainActor
    func getSession(_ sessionID: String) throws -> ConverterSession {
        guard let session = sessions[sessionID] else {
            throw ConverterServerError.unknownSession(sessionID)
        }
        return session
    }

}

/// Each authenticated connection owns its own namespace and bounded session set.
private final class ConnectionEndpoint: NSObject, ConverterServerXPCProtocol, @unchecked Sendable {
    private let server: ConverterServer
    private let prefix = UUID().uuidString + ":"
    private let lock = NSLock()
    private var sessions = Set<String>()
    private var active = true
    init(server: ConverterServer) { self.server = server }
    func invalidate() {
        lock.lock(); active = false
        let ids = sessions; sessions.removeAll(); lock.unlock()
        for id in ids { server.closeSession(prefix + id) { _ in } }
    }
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void) {
        guard message.utf8.count <= 1024 else { reply("Rejected"); return }
        server.ping(message, with: reply)
    }
    func openSession(with reply: @escaping @Sendable (String) -> Void) {
        let id = UUID().uuidString
        handleCommand(try! ConverterServerCodec.encode(.openSession(sessionID: id, command: .composition(.snapshot)))) { data, _ in
            reply(data == nil ? "" : id)
        }
    }
    func closeSession(_ id: String, with reply: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard active, sessions.remove(id) != nil else { reply(false); return }
        server.closeSession(prefix + id, with: reply)
    }
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void) {
        guard data.count <= 262_144 else { reply(nil, "Request too large"); return }
        lock.lock(); defer { lock.unlock() }
        guard active else { reply(nil, "Connection closed"); return }
        do {
            var command = try ConverterServerCodec.decodeCommand(from: data)
            switch command {
            case .openSession(let id, let action):
                guard id.utf8.count <= 128, sessions.contains(id) || sessions.count < 8 else {
                    reply(nil, "Session limit"); return
                }
                sessions.insert(id)
                command = .openSession(sessionID: prefix + id, command: action)
            case .session(let id, let action):
                guard sessions.contains(id) else { reply(nil, "Unknown session"); return }
                command = .session(sessionID: prefix + id, command: action)
            default: break
            }
            server.handleCommand(try ConverterServerCodec.encode(command), with: reply)
        } catch { reply(nil, "Invalid request") }
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    fileprivate let server = ConverterServer()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              let requirement = ConnectionSecurity.requirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
        let endpoint = ConnectionEndpoint(server: server)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.invalidate() }
        connection.resume()
        return true
    }
}

// Deny network before accepting any input or loading the model.
fputs("Local inference network blocked: \(LocalInferenceSecurity.networkBlocked)\n", stderr)
fputs("Local inference network denial verified: \(LocalInferenceSecurity.networkDenialVerified())\n", stderr)
fputs("Local inference model approved: \(LocalInferenceSecurity.approvedModelURL != nil)\n", stderr)
let listener = NSXPCListener(machServiceName: ConverterServerXPC.machServiceName)
private let delegate = ServiceDelegate()
MainActor.assumeIsolated { delegate.server.prepareLocalInference() }
fputs("Local inference startup preparation complete\n", stderr)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
