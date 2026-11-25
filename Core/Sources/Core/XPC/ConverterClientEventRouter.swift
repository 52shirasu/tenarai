import Foundation

/// InputMethodKit の同期 `handle` が返すイベント所有権だけを判断する。
///
/// 変換状態の本体は ConverterServer が所有する。Client は Server が最後に返した
/// 読み取り専用の状態を使い、明らかな application shortcut を同期的に通す。
/// Server の応答待ちがある間は状態が進んでいる可能性があるため、Command shortcut
/// 以外を保守的に consume し、生のキー入力が application へ漏れることを防ぐ。
public enum ConverterClientEventDisposition: Sendable, Equatable {
    case sendToServer
    case fallthroughToApplication
}

public struct ConverterClientEventRoutingContext: Sendable, Equatable {
    public var acknowledgedInputState: ConverterInputState
    public var acknowledgedInputLanguage: InputLanguage
    public var hasPendingKeyEvents: Bool
    public var liveConversionEnabled: Bool
    public var enableDebugWindow: Bool
    public var enableSuggestion: Bool
    public var typeBackSlash: Bool

    public init(
        acknowledgedInputState: ConverterInputState = .none,
        acknowledgedInputLanguage: InputLanguage = .japanese,
        hasPendingKeyEvents: Bool = false,
        liveConversionEnabled: Bool = true,
        enableDebugWindow: Bool = false,
        enableSuggestion: Bool = false,
        typeBackSlash: Bool = false
    ) {
        self.acknowledgedInputState = acknowledgedInputState
        self.acknowledgedInputLanguage = acknowledgedInputLanguage
        self.hasPendingKeyEvents = hasPendingKeyEvents
        self.liveConversionEnabled = liveConversionEnabled
        self.enableDebugWindow = enableDebugWindow
        self.enableSuggestion = enableSuggestion
        self.typeBackSlash = typeBackSlash
    }
}

public enum ConverterClientEventRouter {
    /// Command+Enter is "send" in chat apps. It falls through like every Command
    /// shortcut, but an app that receives it while marked text is still up neither
    /// sends nor commits. The client therefore commits the displayed composition
    /// first, so one Command+Enter both commits and sends. Other Command shortcuts
    /// keep the composition as it is (Command+C, Command+Z and so on act on the app).
    public static func commitsDisplayedCompositionBeforeFallthrough(event: KeyEventCore) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return false
        }
        return event.keyCode == 0x24 || event.keyCode == 0x4C
    }

    public static func disposition(
        event: KeyEventCore,
        context: ConverterClientEventRoutingContext
    ) -> ConverterClientEventDisposition {
        // Command shortcut は composition の有無にかかわらず application が所有する。
        if event.modifierFlags.contains(.command) {
            return .fallthroughToApplication
        }

        // 未応答イベントがある場合、acknowledgedInputState は古い可能性がある。
        // ここで fallthrough するとタイムアウトした文字が英字として漏れるため、
        // Server が順番に処理できるようイベントを consume する。
        if context.hasPendingKeyEvents {
            return .sendToServer
        }

        let inputState = context.acknowledgedInputState.inputState
        let userAction = UserAction.getUserAction(
            eventCore: event,
            inputLanguage: context.acknowledgedInputLanguage,
            typeBackSlash: context.typeBackSlash
        )
        let (action, _) = inputState.event(
            eventCore: event,
            userAction: userAction,
            inputLanguage: context.acknowledgedInputLanguage,
            liveConversionEnabled: context.liveConversionEnabled,
            enableDebugWindow: context.enableDebugWindow,
            enableSuggestion: context.enableSuggestion
        )
        if case .fallthrough = action {
            return .fallthroughToApplication
        }
        return .sendToServer
    }
}
