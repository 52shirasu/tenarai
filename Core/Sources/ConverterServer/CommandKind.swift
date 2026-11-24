import Core

extension ConverterServerCommand {
    /// Command kind without any payload, for content-free logs.
    var kindName: String {
        switch self {
        case .shutdown: "shutdown"
        case .maintenance: "maintenance"
        case .openSession(_, let command), .session(_, let command): command.kindName
        }
    }
}

extension ConverterSessionCommand {
    var kindName: String {
        switch self {
        case .learning: "learning"
        case .lifecycle: "lifecycle"
        case .settings: "settings"
        case .updateConfig: "updateConfig"
        case .handleKeyEvent: "key"
        case .composition: "composition"
        case .candidate: "candidate"
        case .replaceSuggestion: "replaceSuggestion"
        }
    }
}
