import Foundation

@objc private protocol ConverterServerXPCProtocol {
    func openSession(with reply: @escaping @Sendable (String) -> Void)
    func closeSession(_ sessionID: String, with reply: @escaping @Sendable (Bool) -> Void)
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}

/// IME 側の XPC クライアント。コマンドを1件ずつ順番に送り、切断時は再接続する。
@MainActor
public final class ConverterServerClient {
    public nonisolated static let defaultMachServiceName = "local.tenarai.inputmethod.tenarai.ConverterServer"
    private static let commandTimeout: TimeInterval = 1
    private let machServiceName: String

    private var connection: NSXPCConnection?
    private var sessionID: String?
    private var hasOpenedSession = false
    private var shouldAttemptReconnect = false
    private var nextReconnectAttemptDate = Date.distantPast
    private var consecutiveTimeouts = 0
    private static let timeoutsBeforeReconnect = 3
    private let commandQueue = OrderedAsyncCommandQueue<ConverterServerResponse?>()

    public nonisolated init(machServiceName: String = ConverterServerClient.defaultMachServiceName) {
        self.machServiceName = machServiceName
    }

    public var onLog: ((String) -> Void)?
    /// A new server session replaced an earlier one (e.g. the server restarted).
    /// Anything composed in the earlier session no longer exists on the server; it
    /// runs before the reply that opened the new session is delivered.
    public var onSessionReplaced: (() -> Void)?
    /// Content-free event names for diagnostics ("timeout", "connectionReset", ...).
    public var onDiagnosticEvent: ((String) -> Void)?
    public var hasOpenSession: Bool {
        sessionID != nil
    }
    public var canSendOrReconnect: Bool {
        sessionID != nil || !hasOpenedSession || (shouldAttemptReconnect && Date() >= nextReconnectAttemptDate)
    }
    public var pendingCommandCount: Int {
        commandQueue.count
    }

    /// Recovery when a command has had no reply for several seconds: drop the
    /// connection (a fresh session is opened and `onSessionReplaced` keeps what the user
    /// sees) and restart the stuck command on the new connection.
    public func recoverFromStall() {
        onDiagnosticEvent?("stallRecovery")
        onLog?("ConverterServer stall recovery")
        consecutiveTimeouts = 0
        resetConnection(preservingSession: false)
        nextReconnectAttemptDate = .distantPast
        commandQueue.retryActiveNow()
    }

    /// Opens the session ahead of the first key so that key is not delayed by it.
    public func prepareSession() {
        guard sessionID == nil else { return }
        send({ _ in .lifecycle(.activate) }, completion: { _ in })
    }

    public func closeSession() {
        guard let sessionID else {
            invalidateConnection()
            return
        }
        remoteObjectProxy { [weak self] proxy in
            proxy?.closeSession(sessionID) { _ in
                Task { @MainActor in
                    self?.invalidateConnection()
                }
            }
        }
    }

    public func ping(_ message: String, completion: @escaping (String?) -> Void) {
        nonisolated(unsafe) let completion = completion
        remoteObjectProxy { proxy in
            proxy?.ping(message) { response in
                completion(response)
            }
            if proxy == nil {
                completion(nil)
            }
        }
    }

    public func listSettings(
        capabilities: ConverterSettingClientCapabilities,
        completion: @escaping ([ConverterSettingDescriptor]?) -> Void
    ) {
        send(
            { _ in
                .settings(.list(capabilities: capabilities))
            },
            completion: { response in
                completion(response?.settings)
            }
        )
    }

    public func updateSetting(
        key: String,
        value: ConverterSettingValue,
        completion: @escaping (Bool) -> Void
    ) {
        send(
            { _ in
                .settings(.update(key: key, value: value))
            },
            completion: { response in
                completion(response != nil)
            }
        )
    }

    public func restartServer(completion: @escaping (Bool) -> Void) {
        enqueueGlobal(.shutdown) { [weak self] response in
            self?.invalidateConnection()
            completion(response != nil)
        }
    }

    public func synchronizeUserDictionary(
        forceExport: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        enqueueGlobal(.maintenance(.synchronizeUserDictionary(forceExport: forceExport))) { response in
            completion(response != nil)
        }
    }

    public func listLearnedConversions(completion: @escaping ([LearnedConversion]?) -> Void) {
        enqueueGlobal(.maintenance(.listLearnedConversions)) { response in
            completion(response?.learnedConversions)
        }
    }

    public func forgetLearnedConversions(_ items: [LearnedConversion], completion: @escaping ([LearnedConversion]?) -> Void) {
        enqueueGlobal(.maintenance(.forgetLearnedConversions(items))) { response in
            completion(response?.learnedConversions)
        }
    }

    public func resetLearningData(completion: @escaping (Bool) -> Void) {
        enqueueGlobal(.maintenance(.resetLearningData)) { response in
            completion(response != nil)
        }
    }

    public func send(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        enqueue(commandBuilder, retriesOnFailure: false, completion: completion)
    }

    /// キーイベントはタイムアウトで捨てず、1件ずつ順番に Server へ送る。
    /// XPC が一時的に切断した場合も先頭イベントを保持して再接続後に再送する。
    public func sendKeyEvent(
        _ request: ConverterKeyEventRequest,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        enqueue({ _ in .handleKeyEvent(request) }, retriesOnFailure: true, completion: completion)
    }

    public func sendIfSessionOpen(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        guard sessionID != nil else {
            completion(nil)
            return
        }
        enqueue(commandBuilder, retriesOnFailure: false, completion: completion)
    }

    private func enqueue(
        _ commandBuilder: @escaping (String) -> ConverterSessionCommand,
        retriesOnFailure: Bool,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        var proposedSessionID: String?
        commandQueue.enqueue(
            timeout: Self.commandTimeout,
            timeoutOutcome: retriesOnFailure ? .retry : .finish(nil),
            onTimeout: { [weak self] in
                self?.handleCommandTimeout()
            },
            operation: { [weak self] finish in
                guard let self else {
                    finish(.finish(nil))
                    return
                }
                let reconnectDelay = self.nextReconnectAttemptDate.timeIntervalSinceNow
                if self.shouldAttemptReconnect, reconnectDelay > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) {
                        finish(.retry)
                    }
                    return
                }
                let sessionID = self.sessionID ?? proposedSessionID ?? UUID().uuidString
                proposedSessionID = sessionID
                let sessionCommand = commandBuilder(sessionID)
                let command: ConverterServerCommand = if self.sessionID == nil {
                    .openSession(sessionID: sessionID, command: sessionCommand)
                } else {
                    .session(sessionID: sessionID, command: sessionCommand)
                }
                self.sendResolved(command) { [weak self] response in
                    guard let self else {
                        finish(.finish(nil))
                        return
                    }
                    if response != nil, self.sessionID == nil {
                        let replacesEarlierSession = self.hasOpenedSession
                        self.acceptOpenedSession(sessionID)
                        if replacesEarlierSession {
                            self.onDiagnosticEvent?("sessionReplaced")
                            self.onSessionReplaced?()
                        }
                    }
                    if response == nil, retriesOnFailure {
                        self.recordReconnectFailure()
                        finish(.retry)
                    } else {
                        finish(.finish(response))
                    }
                }
            },
            completion: { response in
                completion(response)
            }
        )
    }

    private func enqueueGlobal(
        _ command: ConverterServerCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        commandQueue.enqueue(
            timeout: Self.commandTimeout,
            timeoutOutcome: .finish(nil),
            onTimeout: { [weak self] in
                self?.handleCommandTimeout()
            },
            operation: { [weak self] finish in
                guard let self else {
                    finish(.finish(nil))
                    return
                }
                self.sendResolved(command) { response in
                    finish(.finish(response))
                }
            },
            completion: { response in
                completion(response)
            }
        )
    }

    private func remoteObjectProxy(completion: @escaping (ConverterServerXPCProtocol?) -> Void) {
        let connection = ensureConnection()
        nonisolated(unsafe) let completion = completion
        // XPC calls this handler on its own queue; it must not be MainActor-isolated.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] error in
            let description = error.localizedDescription
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.onLog?("ConverterServer XPC error: \(description)")
                self?.resetConnection(preservingSession: true)
                completion(nil)
            } }
        }) as? ConverterServerXPCProtocol else {
            completion(nil)
            return
        }
        completion(proxy)
    }

    private func sendResolved(
        _ command: ConverterServerCommand,
        completion: @escaping (ConverterServerResponse?) -> Void
    ) {
        nonisolated(unsafe) let completion = completion
        do {
            let data = try ConverterServerCodec.encode(command)
            self.remoteObjectProxy { proxy in
                guard let proxy else {
                    completion(nil)
                    return
                }
                proxy.handleCommand(data) { [weak self] responseData, errorMessage in
                    let errorDescription = errorMessage.map(String.init)
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        if let errorDescription {
                            self?.onLog?("ConverterServer command failed: \(errorDescription)")
                            if ConverterSessionRecovery.requiresNewSession(errorDescription) {
                                self?.resetConnection(preservingSession: false)
                            }
                            completion(nil)
                            return
                        }
                        guard let responseData else {
                            completion(nil)
                            return
                        }
                        self?.consecutiveTimeouts = 0
                        completion(try? ConverterServerCodec.decodeResponse(from: responseData))
                    } }
                }
            }
        } catch {
            self.onLog?("ConverterServer encode failed: \(error.localizedDescription)")
            completion(nil)
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection {
            return connection
        }
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
        connection.interruptionHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.onLog?("ConverterServer connection interrupted")
                self?.resetConnection(preservingSession: true)
            } }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.onLog?("ConverterServer connection invalidated")
                self?.resetConnection(preservingSession: true)
            } }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func resetConnection(preservingSession: Bool) {
        let connection = self.connection
        if connection != nil {
            onDiagnosticEvent?(preservingSession ? "connectionReset" : "sessionLost")
        }
        self.connection = nil
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        if sessionID != nil || hasOpenedSession {
            shouldAttemptReconnect = true
        }
        if !preservingSession {
            self.sessionID = nil
        }
    }

    private func invalidateConnection() {
        resetConnection(preservingSession: false)
    }

    private func recordReconnectFailure() {
        shouldAttemptReconnect = true
        nextReconnectAttemptDate = Date().addingTimeInterval(0.2)
    }

    private func acceptOpenedSession(_ sessionID: String) {
        self.sessionID = sessionID
        hasOpenedSession = true
        shouldAttemptReconnect = false
        nextReconnectAttemptDate = .distantPast
        onLog?("ConverterServer session opened: \(sessionID)")
    }

    private func handleCommandTimeout() {
        onLog?("ConverterServer command timed out")
        onDiagnosticEvent?("timeout")
        consecutiveTimeouts += 1
        // Sessions belong to a connection. A slow but alive server (model warm-up,
        // CPU spike) keeps the session only if we keep the connection; reconnecting
        // opened a new, empty session and discarded the composition. Retried key
        // events reuse their event ID, so the server answers duplicates from cache.
        guard consecutiveTimeouts >= Self.timeoutsBeforeReconnect else {
            return
        }
        consecutiveTimeouts = 0
        recordReconnectFailure()
        resetConnection(preservingSession: true)
    }
}
