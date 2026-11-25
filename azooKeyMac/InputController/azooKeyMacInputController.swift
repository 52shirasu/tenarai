import os
import Carbon
import Cocoa
import Core
import InputMethodKit

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController, NSMenuItemValidation { // swiftlint:disable:this type_name
    let converterServerClient = ConverterServerClient()
    private var currentConverterView: ConverterSessionSnapshot?
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    private var pendingKeyEventCount = 0
    private var lastRepliedKeyEventID: UInt64 = 0
    /// How long the key took from the keyboard to `handle` (the app forwards it).
    private var keyDeliveryLagMs: Double = 0
    /// Set while a reply that inserted text is being applied. Asking the app for its
    /// marked range right after `insertText` waits until the app has processed the
    /// insertion: 0.3-3 s in Electron apps (measured 2026-11-19), with the IME's main
    /// thread blocked, so the hidden candidate list stayed on screen and keys queued up.
    private var insertedTextInCurrentApply = false
    private var isWaitingForPendingKeyEvents = false
    /// Content-free pipeline events (`log stream --predicate 'subsystem == "local.tenarai.tenarai"'`).
    static let pipelineLog = Logger(subsystem: "local.tenarai.tenarai", category: "pipeline")
    /// One recorder for the whole IME process: every client app gets its own controller,
    /// and separate recorders overwrote each other's saved statistics.
    @MainActor private static let sharedTiming = ClientTimingDiagnostics()
    @MainActor private var timing: ClientTimingDiagnostics { Self.sharedTiming }
    private var nextKeyEventID: UInt64 = 0
    private var activationGeneration: UInt64 = 0
    private var pendingPaste: PendingPaste?
    private var textObservationTimer: Timer?
    private var observedClient: ObjectIdentifier?
    private var observedText: String?
    private var suppressNextExternalObservation = false
    /// Bumped by every local input-mode switch (setValue). A key reply carries the
    /// language the server had when it handled the key; it must not undo a newer switch.
    private var inputLanguageSwitchGeneration: UInt64 = 0
    /// What the client is showing as marked text, when known. `refreshMarkedText` only
    /// calls `setMarkedText` when this changes.
    private var appliedMarkedText: ConverterMarkedText?
    /// Logged once per activation, so a password field does not log every key.
    private var loggedSecureInputBypass = false

    /// Whether the client is a password field (or another secure text entry): its app
    /// holds Secure Event Input. Such keys must reach the app untouched.
    @MainActor private func isSecureInputClient(_ client: IMKTextInput) -> Bool {
        let enabled = IsSecureEventInputEnabled()
        guard enabled else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let ownerPID = (session?["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        let clientPIDs = client.bundleIdentifier().map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)
        } ?? []
        return SecureInputPolicy.bypassesInputMethod(secureInputEnabled: enabled, ownerPID: ownerPID, clientPIDs: clientPIDs)
    }

    @MainActor private func observeExternalText(baselineOnly: Bool = false) {
        guard pendingKeyEventCount == 0, let client = self.client(),
              // Never read (or learn) the contents of a password field.
              !self.isSecureInputClient(client),
              client.markedRange().location == NSNotFound else { return }
        let identity = ObjectIdentifier(client as AnyObject)
        let length = client.length()
        guard length >= 0, length <= 131072 else { observedText = nil; return }
        let range = NSRange(location: 0, length: length)
        var actual = NSRange(location: NSNotFound, length: 0)
        guard let text = client.string(from: range, actualRange: &actual), actual == range else { return }
        let suppress = suppressNextExternalObservation
        defer { observedClient = identity; observedText = text; suppressNextExternalObservation = false }
        guard !baselineOnly, !suppress, observedClient == identity, let before = observedText,
              let added = ExternalTextChange.insertion(from: before, to: text) else { return }
        converterServerClient.send({ _ in .learning(.observe(text: added, origin: .unknown)) }, completion: { _ in })
    }
    private var pendingConverterServerActivation: ConverterSessionActivation?
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    private var replaceSuggestionWindow: NSWindow
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    func appendDebugMessage(_ message: String) {
        // Never emit input-derived text, prompts or errors to persistent logs.
        // Call sites may contain user text, including in Debug builds.
        _ = message
    }

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = Config.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: predictionViewController)
        self.replaceSuggestionWindow = Self.makeCandidateWindow(contentViewController: replaceSuggestionsViewController)

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        MainActor.assumeIsolated {
            self.converterServerClient.onLog = { [weak self] message in
                // Client messages carry no input text (errors, timeouts, session ids).
                Self.pipelineLog.notice("\(message, privacy: .public)")
                self?.appendDebugMessage(message)
            }
            self.converterServerClient.onSessionReplaced = { [weak self] in
                self?.converterServerSessionReplaced()
            }
            self.converterServerClient.onDiagnosticEvent = { [weak self] event in
                self?.timing.count(event)
            }
        }
        self.setupMenu()
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        self.activationGeneration &+= 1
        Self.pipelineLog.notice("activate app=\((sender as? IMKTextInput)?.bundleIdentifier() ?? "?", privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public) queue=\(self.converterServerClient.pendingCommandCount, privacy: .public) session=\(self.converterServerClient.hasOpenSession, privacy: .public)")
        self.pendingPaste = nil
        self.observedText = nil
        self.observedClient = nil
        // A newly activated client shows no marked text of ours.
        self.appliedMarkedText = ConverterSessionSnapshot.empty.markedText
        self.loggedSecureInputBypass = false
        self.textObservationTimer?.invalidate()
        self.textObservationTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.timing.measure("documentObservation") { self.observeExternalText() }
            }
        }
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        // ピン留めプロンプトのキャッシュを更新
        self.reloadPinnedPromptsCache()
        self.pendingConverterServerActivation = ConverterSessionActivation(
            config: self.converterServerSessionConfig,
            inputLanguage: self.inputLanguage,
            clientIdentifier: (sender as? IMKTextInput)?.bundleIdentifier()
        )

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        }
        // Open the server session now rather than with the first key: keys typed while
        // the first one waited for the session used to queue up (and pass-through keys
        // had to wait).
        self.converterServerClient.prepareSession()
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.activationGeneration &+= 1
        self.pendingPaste = nil
        self.textObservationTimer?.invalidate()
        self.textObservationTimer = nil
        self.observedText = nil
        self.observedClient = nil
        self.pendingConverterServerActivation = nil
        self.appliedMarkedText = nil
        self.timing.flush()
        self.converterServerClient.sendIfSessionOpen({ _ in .lifecycle(.deactivate) }, completion: { _ in })
        self.currentConverterView = nil
        self.inputState = .none
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    /// Inserts the marked text the user currently sees and forgets the local view.
    /// - Returns: the inserted text, or `nil` when nothing was displayed.
    @MainActor
    @discardableResult
    private func insertDisplayedComposition(into client: IMKTextInput) -> String? {
        guard let view = self.currentConverterView else {
            return nil
        }
        let text = view.markedText.elements.map(\.content).joined()
        self.currentConverterView = nil
        self.inputState = .none
        guard !text.isEmpty else {
            return nil
        }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        self.appliedMarkedText = ConverterSessionSnapshot.empty.markedText
        self.suppressNextExternalObservation = true
        return text
    }

    /// The server restarted and the new session has no composition. Keep what the
    /// user sees instead of letting the next reply replace it, and resend the
    /// activation so the new session uses the current input language.
    @MainActor
    private func converterServerSessionReplaced() {
        if let client = self.client() {
            self.insertDisplayedComposition(into: client)
        }
        self.pendingConverterServerActivation = ConverterSessionActivation(
            config: self.converterServerSessionConfig,
            inputLanguage: self.inputLanguage,
            clientIdentifier: self.client()?.bundleIdentifier()
        )
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        let client = (sender as? IMKTextInput) ?? self.client()
        // See CompositionCommitPlan: insert what is displayed now, because IMK
        // deactivates right after this call and a late reply would be discarded.
        let plan = CompositionCommitPlan.make(pendingKeyEvents: self.pendingKeyEventCount, displayed: self.currentConverterView)
        if case .insertDisplayedText = plan, let client {
            self.timing.count("commitCompositionImmediate")
            if let text = self.insertDisplayedComposition(into: client) {
                self.converterServerClient.send({ _ in .learning(.observe(text: text, origin: .typed)) }) { _ in }
            }
            self.converterServerClient.sendIfSessionOpen({ _ in .composition(.commit) }, completion: { _ in })
            self.refreshCandidateWindow()
            self.refreshPredictionWindow()
            return
        }
        let activationGeneration = self.activationGeneration
        self.converterServerClient.sendIfSessionOpen({ _ in .composition(.commit) }, completion: { [weak self] response in
            Task { @MainActor in
                guard let self, let response else {
                    return
                }
                guard self.activationGeneration == activationGeneration else {
                    self.timing.count("commitCompositionAfterDeactivation")
                    // Deactivated meanwhile: still hand the committed text to the
                    // client that asked for the commit instead of discarding it.
                    for case .insertText(let text) in response.effects {
                        client?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                    }
                    return
                }
                self.apply(response)
            }
        })
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            let englishMode = value == "com.apple.inputmethod.Roman"
            let language: InputLanguage = englishMode ? .english : .japanese
            Self.pipelineLog.notice("mode \(englishMode ? "roman" : "japanese", privacy: .public) was=\(String(describing: self.inputLanguage), privacy: .public) pendingActivation=\(self.pendingConverterServerActivation != nil, privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public)")
            if self.inputLanguage != language {
                self.inputLanguageSwitchGeneration &+= 1
            }
            // A pending activation goes out with the next key and the server applies its
            // language; with the old mode it would undo the synchronize sent below.
            self.pendingConverterServerActivation?.inputLanguage = language

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    self.inputLanguage = .english
                    self.converterServerClient.send(
                        { _ in .lifecycle(.synchronizeInputLanguage(.english)) },
                        completion: { _ in }
                    )
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    self.converterServerClient.send(
                        { _ in .lifecycle(.synchronizeInputLanguage(.japanese)) },
                        completion: { _ in }
                    )
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        guard event.type == .keyDown else {
            return false
        }
        self.keyDeliveryLagMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        if self.isSecureInputClient(client) {
            if !self.loggedSecureInputBypass {
                self.loggedSecureInputBypass = true
                Self.pipelineLog.notice("secure input field: keys pass to the app pending=\(self.pendingKeyEventCount, privacy: .public) marked=\(self.currentConverterView.map { !$0.isEmpty } ?? false, privacy: .public)")
            }
            // Keep whatever was being composed before the field became secure.
            if self.currentConverterView.map({ !$0.isEmpty }) ?? false {
                self.insertDisplayedComposition(into: client)
                self.converterServerClient.sendIfSessionOpen({ _ in .composition(.stopComposition) }, completion: { _ in })
                self.refreshCandidateWindow()
                self.refreshPredictionWindow()
            }
            return false
        }
        Self.pipelineLog.debug("key in \(Self.keyClass(event.keyEventCore), privacy: .public) mods=\(event.modifierFlags.intersection([.shift, .control, .option, .command]).rawValue, privacy: .public) lang=\(String(describing: self.inputLanguage), privacy: .public) state=\(String(describing: self.inputState), privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public)")

        if let paste = pendingPaste {
            pendingPaste = nil
            if client.markedRange().location == NSNotFound,
               let range = paste.insertedRange(selection: client.selectedRange(), documentLength: client.length()) {
                var actual = NSRange(location: NSNotFound, length: 0)
                if let text = client.string(from: NSRange(location: range.location, length: min(range.length, 32768)), actualRange: &actual), actual.location == range.location, actual.length <= range.length, !text.isEmpty {
                    converterServerClient.send({ _ in .learning(.observe(text: text, origin: .pasted)) }, completion: { _ in })
                }
            }
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v",
           client.markedRange().location == NSNotFound {
            pendingPaste = PendingPaste(selection: client.selectedRange(), documentLength: client.length())
        }

        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                        return true
                    }
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        return true
                    }
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        return true
                    }
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                guard aiBackendEnabled else {
                    self.appendDebugMessage("Suggest action ignored: AI backend is off")
                    return false
                }
                self.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                self.showPromptInputWindow()
                return true
            } else {
                self.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        return self.handleKeyEventWithConverterServer(
            event: event.keyEventCore,
            enableSuggestion: aiBackendEnabled,
            optionDirectInputText: event.characters(byApplyingModifiers: event.modifierFlags.subtracting([.option, .capsLock]))
        )
    }

    @MainActor
    private func handleKeyEventWithConverterServer(
        event: KeyEventCore,
        enableSuggestion: Bool,
        optionDirectInputText: String? = nil
    ) -> Bool {
        // A key that may belong to the app (Enter to send, Backspace, arrows, shortcuts)
        // must not be decided on a stale state, and must reach the app after the text
        // committed by earlier keys. While earlier keys are still waiting for the server
        // it used to be consumed; when the server then said "fall through" it was lost
        // (e.g. Discord: Enter to commit, Enter to send -> the send vanished).
        let handleStartedAt = DispatchTime.now().uptimeNanoseconds
        let deliveryLagMs = self.keyDeliveryLagMs
        self.keyDeliveryLagMs = 0
        let keyClass = Self.keyClass(event)
        if self.pendingKeyEventCount > 0, !self.isWaitingForPendingKeyEvents,
           Self.mayBelongToApplication(event, inputLanguage: self.inputLanguage) {
            self.waitForPendingKeyEvents(timeout: 0.5)
        }
        // Command+Enter (send): commit what is displayed, then let the key reach the app.
        if ConverterClientEventRouter.commitsDisplayedCompositionBeforeFallthrough(event: event),
           case .insertDisplayedText = CompositionCommitPlan.make(pendingKeyEvents: self.pendingKeyEventCount, displayed: self.currentConverterView),
           let client = self.client() {
            self.timing.count("commitBeforeCommandEnter")
            if let text = self.insertDisplayedComposition(into: client) {
                self.converterServerClient.send({ _ in .learning(.observe(text: text, origin: .typed)) }) { _ in }
            }
            self.converterServerClient.sendIfSessionOpen({ _ in .composition(.commit) }, completion: { _ in })
            self.refreshCandidateWindow()
            self.refreshPredictionWindow()
        }
        let disposition = ConverterClientEventRouter.disposition(
            event: event,
            context: .init(
                acknowledgedInputState: ConverterInputState(self.inputState),
                acknowledgedInputLanguage: self.inputLanguage,
                hasPendingKeyEvents: self.pendingKeyEventCount > 0,
                liveConversionEnabled: Config.LiveConversion().value,
                enableDebugWindow: Config.DebugWindow().value,
                enableSuggestion: enableSuggestion,
                typeBackSlash: Config.TypeBackSlash().value
            )
        )
        guard disposition == .sendToServer else {
            Self.pipelineLog.debug("key passthrough pending=\(self.pendingKeyEventCount, privacy: .public)")
            return false
        }

        self.nextKeyEventID &+= 1
        let request = ConverterKeyEventRequest(
            eventID: self.nextKeyEventID,
            event: event,
            inputStyle: self.inputStyle,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: enableSuggestion,
            enablePredictiveTyping: Config.DebugPredictiveTyping().value,
            enableTypoCorrection: Config.DebugTypoCorrection().value,
            enableOptionDirectFullWidthInput: Config.OptionDirectFullWidthInput().value,
            typeBackSlash: Config.TypeBackSlash().value,
            optionDirectInputText: optionDirectInputText,
            context: self.timing.measure("contextFetch") { self.currentConverterTextContext() },
            activation: self.pendingConverterServerActivation
        )
        let sentAt = DispatchTime.now().uptimeNanoseconds
        let languageGeneration = self.inputLanguageSwitchGeneration
        self.pendingConverterServerActivation = nil
        self.pendingKeyEventCount += 1
        Self.pipelineLog.debug("key \(request.eventID, privacy: .public) sent pending=\(self.pendingKeyEventCount, privacy: .public) queue=\(self.converterServerClient.pendingCommandCount, privacy: .public)")
        if self.pendingKeyEventCount >= 5 {
            Self.pipelineLog.notice("backlog key=\(request.eventID, privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public) queue=\(self.converterServerClient.pendingCommandCount, privacy: .public) session=\(self.converterServerClient.hasOpenSession, privacy: .public)")
        }
        // Watchdog: a key without a reply for 3 s is the "nothing appears" symptom.
        let watchedID = request.eventID
        let watchedGeneration = self.activationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.lastRepliedKeyEventID < watchedID, self.activationGeneration == watchedGeneration else { return }
            Self.pipelineLog.notice("stall key=\(watchedID, privacy: .public) noReplyFor=3s pending=\(self.pendingKeyEventCount, privacy: .public) queue=\(self.converterServerClient.pendingCommandCount, privacy: .public) session=\(self.converterServerClient.hasOpenSession, privacy: .public)")
            // Self-heal instead of needing an IME restart.
            self.converterServerClient.recoverFromStall()
        }
        let activationGeneration = self.activationGeneration
        self.converterServerClient.sendKeyEvent(request) { [weak self] response in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.pendingKeyEventCount = max(0, self.pendingKeyEventCount - 1)
                self.lastRepliedKeyEventID = max(self.lastRepliedKeyEventID, request.eventID)
                let repliedAt = DispatchTime.now().uptimeNanoseconds
                self.timing.record("keyRoundTrip", milliseconds: Double(repliedAt - sentAt) / 1_000_000)
                guard self.activationGeneration == activationGeneration else {
                    Self.pipelineLog.notice("key \(request.eventID, privacy: .public) reply after deactivation ignored")
                    return
                }
                guard let response else {
                    Self.pipelineLog.error("key \(request.eventID, privacy: .public) dropped (no response)")
                    self.appendDebugMessage("ConverterServer dropped key event \(request.eventID)")
                    return
                }
                let inserts = response.effects.filter { if case .insertText = $0 { return true }; return false }.count
                if !response.handled {
                    Self.pipelineLog.notice("key \(request.eventID, privacy: .public) fallthrough after send (consumed) state=\(String(describing: response.inputState), privacy: .public)")
                }
                Self.pipelineLog.debug("key \(request.eventID, privacy: .public) reply handled=\(response.handled, privacy: .public) inserts=\(inserts, privacy: .public) marked=\(!response.snapshot.isEmpty, privacy: .public) pending=\(self.pendingKeyEventCount, privacy: .public)")
                if !response.handled {
                    // `handle` は既に同期的に consume 済み。未応答イベントがある場合は
                    // application へ後からイベントを戻せないため、ここでは漏らさない。
                    self.appendDebugMessage("Consumed delayed fallthrough event \(request.eventID)")
                }
                let adoptsLanguage = self.inputLanguageSwitchGeneration == languageGeneration
                if !adoptsLanguage, response.inputLanguage != self.inputLanguage {
                    Self.pipelineLog.notice("key \(request.eventID, privacy: .public) reply language \(String(describing: response.inputLanguage), privacy: .public) ignored: newer local switch to \(String(describing: self.inputLanguage), privacy: .public)")
                }
                let listWasShown = self.candidatesWindow.isVisible
                self.apply(response, adoptsInputLanguage: adoptsLanguage)
                // Content-free: where the time between the key press and the screen went.
                let appliedAt = DispatchTime.now().uptimeNanoseconds
                let totalMs = deliveryLagMs + Double(appliedAt - handleStartedAt) / 1_000_000
                let listHidden = listWasShown && !self.candidatesWindow.isVisible
                self.timing.record("keyDelivery", milliseconds: deliveryLagMs)
                self.timing.record("keyToScreen", milliseconds: totalMs)
                if listHidden {
                    self.timing.record("candidateListHide", milliseconds: totalMs)
                }
                if totalMs >= 250 {
                    Self.pipelineLog.notice("slow key class=\(keyClass, privacy: .public) total=\(Int(totalMs), privacy: .public)ms delivery=\(Int(deliveryLagMs), privacy: .public)ms beforeSend=\((sentAt - handleStartedAt) / 1_000_000, privacy: .public)ms roundTrip=\((repliedAt - sentAt) / 1_000_000, privacy: .public)ms apply=\((appliedAt - repliedAt) / 1_000_000, privacy: .public)ms listHidden=\(listHidden, privacy: .public) app=\(self.client()?.bundleIdentifier() ?? "?", privacy: .public)")
                }
                if case .hidden = response.snapshot.candidateWindow {
                    self.verifyCandidateWindowIsGone()
                }
            }
        }
        return true
    }

    /// The list must be off the screen once the server says it is hidden. If it is still
    /// there a moment later, record that and take it down again.
    @MainActor
    private func verifyCandidateWindowIsGone() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            if let view = self.currentConverterView {
                guard case .hidden = view.candidateWindow else { return }
            }
            guard self.candidatesWindow.isVisible else { return }
            self.timing.count("candidateListStuck")
            Self.pipelineLog.notice("candidate list still visible after hide; ordering out again")
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
        }
    }

    /// Content-free description of a key for the pipeline log (never the character).
    static func keyClass(_ event: KeyEventCore) -> String {
        switch event.keyCode {
        case 18, 19, 20, 21, 22, 23, 25, 26, 28, 29: return "digit"
        case 49: return "space"
        case 36, 76: return "enter"
        case 51: return "backspace"
        case 48: return "tab"
        default:
            guard let scalar = event.characters?.unicodeScalars.first, event.characters?.unicodeScalars.count == 1 else { return "other" }
            if CharacterSet.uppercaseLetters.contains(scalar) { return "upper" }
            if CharacterSet.letters.contains(scalar) { return "letter" }
            return "other"
        }
    }

    /// Keys whose meaning depends on the composition state and that fall through to the
    /// app when nothing is being composed. Characters never wait.
    static func mayBelongToApplication(_ event: KeyEventCore, inputLanguage: InputLanguage) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return true
        }
        switch UserAction.getUserAction(eventCore: event, inputLanguage: inputLanguage, typeBackSlash: Config.TypeBackSlash().value) {
        case .enter, .backspace, .escape, .tab, .navigation, .unknown, .function:
            return true
        default:
            return false
        }
    }

    /// Lets the replies of in-flight keys arrive (and their text be inserted) before the
    /// next key is routed. Replies are delivered on the main queue, so the run loop is
    /// turned here; keys arriving meanwhile are queued in order instead of waiting.
    @MainActor
    private func waitForPendingKeyEvents(timeout: TimeInterval) {
        self.isWaitingForPendingKeyEvents = true
        defer { self.isWaitingForPendingKeyEvents = false }
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)
        while self.pendingKeyEventCount > 0, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
        let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
        if self.pendingKeyEventCount > 0 {
            Self.pipelineLog.notice("wait for pending keys timed out after \(waitedMs, privacy: .public)ms pending=\(self.pendingKeyEventCount, privacy: .public)")
        } else {
            Self.pipelineLog.debug("waited \(waitedMs, privacy: .public)ms for pending keys")
            self.timing.record("waitBeforePassThrough", milliseconds: Double(waitedMs))
        }
    }

    @MainActor
    func requestPredictiveSuggestionWithConverterServer(client: IMKTextInput) -> Bool {
        self.handleKeyEventWithConverterServer(
            event: KeyEventCore(
                modifierFlags: [.control],
                characters: "s",
                charactersIgnoringModifiers: "s",
                keyCode: 1
            ),
            enableSuggestion: Config.AIBackendPreference().value != .off
        )
    }

    @MainActor
    private func apply(_ response: ConverterServerResponse, adoptsInputLanguage: Bool = true) {
        if adoptsInputLanguage, let inputLanguage = response.inputLanguage {
            self.inputLanguage = inputLanguage
        }
        self.inputState = response.inputState.inputState
        self.currentConverterView = response.snapshot
        if case .selecting(let candidates, let selection) = response.snapshot.candidateWindow {
            // Content-free check of what the user sees: highlighted row vs converted text.
            let focused = response.snapshot.markedText.elements.filter { $0.focus == .focused }.map(\.content).joined()
            let highlighted = selection.flatMap { candidates.indices.contains($0) ? candidates[$0].text : nil }
            Self.pipelineLog.debug("candidates row=\(selection ?? -1, privacy: .public) count=\(candidates.count, privacy: .public) highlightMatchesField=\(highlighted == focused, privacy: .public)")
        }
        // Take the candidate list off the screen before anything is sent to the app:
        // inserting text waits for the app, and while a busy app took its time the list
        // of an already committed conversion stayed visible (2026-11-19).
        if case .hidden = response.snapshot.candidateWindow {
            self.refreshCandidateWindow()
            CATransaction.flush()
        }
        self.insertedTextInCurrentApply = false
        if let client = self.client() {
            for effect in response.effects {
                self.apply(effect, client: client)
            }
        }
        self.refreshMarkedText()
        self.insertedTextInCurrentApply = false
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
    }

    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private func apply(_ effect: ConverterClientEffect, client: IMKTextInput) {
        switch effect {
        case .insertText(let text):
            self.timing.measure("commitInsertText") {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            // insertText replaces the client's marked text.
            self.appliedMarkedText = ConverterSessionSnapshot.empty.markedText
            self.insertedTextInCurrentApply = true
            // The next periodic observation re-baselines without learning our own
            // insertion. Reading the whole document here, right after insertText,
            // blocked the main thread for up to 2 s in real apps (diagnostics, Oct 5).
            self.suppressNextExternalObservation = true
            self.timing.count("commitInsert")
            // Observe only committed text, not every live conversion hypothesis.
            self.converterServerClient.send({ _ in .learning(.observe(text: text, origin: .typed)) }) { _ in }
        case .switchInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .requestPredictiveSuggestion:
            self.requestReplaceSuggestion()
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: 1)
        case .selectPreviousReplaceSuggestionCandidate:
            self.selectReplaceSuggestionCandidate(offset: -1)
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
        case .showPromptInputWindow:
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        case .fallthroughToApplication:
            break
        }
    }

    private var inputStyle: ConverterInputStyle {
        switch Config.InputStyle().value {
        case .default:
            .defaultRomanToKana
        case .defaultAZIK:
            .defaultAZIK
        case .defaultKanaUS:
            .defaultKanaUS
        case .defaultKanaJIS:
            .defaultKanaJIS
        case .custom:
            .tableName(CustomInputTableStore.tableName)
        }
    }

    private var converterServerSessionConfig: ConverterSessionConfig {
        ConverterSessionConfig(
            aiBackendPreference: Config.AIBackendPreference().value,
            openAIModelName: Config.OpenAiModelName().value,
            openAIEndpoint: Config.OpenAiApiEndpoint().value,
            openAIAPIKey: .init(Config.OpenAiApiKey().value),
            includeContextInAITransform: Config.IncludeContextInAITransform().value
        )
    }

    @MainActor
    private func syncConverterServerSessionConfig() {
        let config = self.converterServerSessionConfig
        self.converterServerClient.send(
            { _ in .updateConfig(config) },
            completion: { _ in }
        )
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("local.tenarai.inputmethod.tenarai.Roman")
        case .japanese:
            client.selectMode("local.tenarai.inputmethod.tenarai.Japanese")
        }
    }

    @MainActor
    private func discardConverterServerComposition() {
        self.currentConverterView = nil
        self.converterServerClient.sendIfSessionOpen(
            { _ in .composition(.stopComposition) },
            completion: { _ in }
        )
    }

    func refreshCandidateWindow() {
        if let currentConverterView {
            self.refreshCandidateWindow(currentConverterView.candidateWindow)
            return
        }
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
    }

    private func refreshCandidateWindow(_ candidateWindow: ConverterCandidateWindow) {
        switch candidateWindow {
        case .selecting(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = true
            self.candidatesViewController.updateCandidatePresentations(
                candidates,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = false
            self.candidatesViewController.updateCandidatePresentations(
                candidates,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    @MainActor private func refreshReplaceSuggestionWindow() {
        guard self.inputState == .replaceSuggestion,
              let currentConverterView,
              !currentConverterView.replaceSuggestionCandidates.isEmpty else {
            self.replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
            return
        }
        self.replaceSuggestionsViewController.updateCandidatePresentations(
            currentConverterView.replaceSuggestionCandidates,
            selectionIndex: currentConverterView.replaceSuggestionSelectionIndex,
            cursorLocation: self.getCursorLocation()
        )
        self.replaceSuggestionWindow.setIsVisible(true)
        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
    }

    @MainActor private func selectReplaceSuggestionCandidate(offset: Int) {
        guard let view = self.currentConverterView,
              !view.replaceSuggestionCandidates.isEmpty else {
            return
        }
        let count = view.replaceSuggestionCandidates.count
        let current = view.replaceSuggestionSelectionIndex ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + count) % count
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.selectReplaceSuggestionCandidate(index: next)) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    @MainActor private func showReplaceSuggestionError(message: String) {
        self.appendDebugMessage("APIリクエストエラー: \(message)")
        let alert = NSAlert()
        alert.messageText = "変換に失敗しました"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        guard let predictions = self.currentConverterView?.predictionCandidates else {
            self.hidePredictionWindow()
            return
        }
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { ConverterCandidatePresentation(text: $0.displayText) }

        self.lastPredictionCandidates = predictions.map(\.displayText)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates,
            selectionIndex: nil,
            cursorLocation: rect.origin
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { ConverterCandidatePresentation(text: $0) }
        guard !candidates.isEmpty else {
            return
        }
        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates,
            selectionIndex: nil,
            cursorLocation: rect.origin
        )
        self.predictionWindow.orderFront(nil)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    func refreshMarkedText() {
        let currentMarkedText = self.currentMarkedText()
        // Re-sending the same (often empty) marked text is not free: a web page sees
        // composition events for nothing. Skip only while the client still shows exactly
        // what was set last; an app may drop or replace marked text on its own.
        if currentMarkedText == self.appliedMarkedText, self.insertedTextInCurrentApply {
            // insertText just replaced the marked text and nothing new is to be shown.
            return
        }
        if currentMarkedText == self.appliedMarkedText,
           let client = self.client() {
            let checkStartedAt = DispatchTime.now().uptimeNanoseconds
            let markedRange = client.markedRange()
            let checkMs = Double(DispatchTime.now().uptimeNanoseconds - checkStartedAt) / 1_000_000
            MainActor.assumeIsolated { self.timing.record("markedRangeCheck", milliseconds: checkMs) }
            let shownLength = markedRange.location == NSNotFound ? 0 : markedRange.length
            let appliedLength = currentMarkedText.elements.reduce(0) { $0 + ($1.content as NSString).length }
            if shownLength == appliedLength {
                return
            }
            Self.pipelineLog.notice("marked text changed by the client: shown=\(shownLength, privacy: .public) applied=\(appliedLength, privacy: .public); setting it again")
        }
        self.appliedMarkedText = currentMarkedText
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        for part in currentMarkedText.elements where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        self.client()?.setMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange.nsRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func currentMarkedText() -> ConverterMarkedText {
        if let currentConverterView {
            return currentConverterView.markedText
        }
        return ConverterSessionSnapshot.empty.markedText
    }
}

extension azooKeyMacInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            guard self.currentConverterView != nil else {
                return
            }
            self.converterServerClient.sendIfSessionOpen(
                { _ in .candidate(.submitSelectedCandidate(context: self.currentConverterTextContext())) },
                completion: { [weak self] response in
                    Task { @MainActor in
                        guard let self, let response else {
                            return
                        }
                        self.apply(response)
                    }
                }
            )
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Self.pipelineLog.debug("candidate window selected row=\(row, privacy: .public)")
        Task { @MainActor in
            guard self.currentConverterView != nil else {
                return
            }
            self.converterServerClient.sendIfSessionOpen(
                { _ in .candidate(.selectCandidate(index: row)) },
                completion: { [weak self] response in
                    Task { @MainActor in
                        guard let self, let response else {
                            return
                        }
                        self.apply(response)
                    }
                }
            )
        }
    }
}

extension azooKeyMacInputController {
    private func currentConverterTextContext() -> ConverterTextContext {
        ConverterTextContext(
            leftSideContext: self.getLeftSideContext(),
            rightSideContext: self.getRightSideContext()
        )
    }

    func getLeftSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit) -> String? {
        boundedContext(maxCount: maxCount, left: true)
    }

    func getRightSideContext(maxCount: Int = ConverterTextContext.transportCharacterLimit) -> String? {
        boundedContext(maxCount: maxCount, left: false)
    }

    private func boundedContext(maxCount: Int, left: Bool) -> String? {
        guard let client = self.client() else { return nil }
        let marked = client.markedRange(), selected = client.selectedRange(), length = client.length()
        if Config.object(forKey: "tenarai.contextDiagnostics") as? Bool == true {
            Config.set(["length": length, "marked": marked.location, "selected": selected.location,
                        "returned": -1], forKey: left ? "tenarai.leftProbe" : "tenarai.rightProbe")
        }
        let cursor = marked.location == NSNotFound ? selected : marked
        let ranges = TextContextBounds.surrounding(marked: marked, selected: selected, length: length, limit: maxCount)
        let range: NSRange
        if let ranges { range = left ? ranges.left : ranges.right }
        else if left, cursor.location != NSNotFound, cursor.location >= 0, cursor.length >= 0 {
            // Some IMK clients report no document length but do report a valid caret.
            let count = min(cursor.location, maxCount)
            range = NSRange(location: cursor.location - count, length: count)
        } else { return nil }
        if range.length == 0 { return "" }
        var actual = NSRange(location: NSNotFound, length: 0)
        let text = client.string(from: range, actualRange: &actual)
        if Config.object(forKey: "tenarai.contextDiagnostics") as? Bool == true {
            Config.set(["length": length, "marked": marked.location, "selected": selected.location,
                        "requested": range.length, "actual": actual.length,
                        "actualLocation": actual.location, "returned": text?.utf16.count ?? -1],
                       forKey: left ? "tenarai.leftProbe" : "tenarai.rightProbe")
        }
        guard let text, TextContextBounds.valid(actual, length: range.location + range.length),
              actual.location >= range.location else { return nil }
        return left ? String(text.suffix(maxCount)) : String(text.prefix(maxCount))
    }

    private func contextRange() -> NSRange {
        let markedRange = self.client().markedRange()
        if markedRange.location != NSNotFound {
            return markedRange
        }
        let selectedRange = self.client().selectedRange()
        if selectedRange.location != NSNotFound {
            return selectedRange
        }
        return NSRange(location: 0, length: 0)
    }
}

extension azooKeyMacInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        guard self.currentConverterView?.replaceSuggestionSelectionIndex != row else {
            return
        }
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.selectReplaceSuggestionCandidate(index: row)) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            self.submitSelectedSuggestionCandidate()
        }
    }
}

// Suggest Candidate
extension azooKeyMacInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion() {
        self.appendDebugMessage("requestReplaceSuggestion: 開始")

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.replaceSuggestionsViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)

        guard let currentConverterView, !currentConverterView.isEmpty else {
            self.appendDebugMessage("requestReplaceSuggestion: skipped because converter server composition is empty")
            return
        }
        self.syncConverterServerSessionConfig()
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.request(context: self.currentConverterTextContext())) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self else {
                        return
                    }
                    guard let response else {
                        self.showReplaceSuggestionError(message: "ConverterServerから候補を取得できませんでした")
                        return
                    }
                    guard self.currentConverterView?.convertTarget == response.snapshot.convertTarget else {
                        self.appendDebugMessage("候補ウィンドウ更新をスキップ: composition changed")
                        return
                    }
                    self.currentConverterView = response.snapshot
                    self.inputState = response.inputState.inputState
                    self.refreshMarkedText()
                    self.refreshReplaceSuggestionWindow()
                }
            }
        )
        self.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        self.converterServerClient.sendIfSessionOpen(
            { _ in .replaceSuggestion(.submitSelectedReplaceSuggestion) },
            completion: { [weak self] response in
                Task { @MainActor in
                    guard let self, let response else {
                        return
                    }
                    self.apply(response)
                }
            }
        )
    }

    @MainActor private func finishReplaceSuggestionComposition() {
        if self.currentConverterView != nil {
            self.discardConverterServerComposition()
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        self.refreshReplaceSuggestionWindow()
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
