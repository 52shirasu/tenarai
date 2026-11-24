import Foundation

/// How the IME client answers IMK's `commitComposition` (focus changes, clicks).
///
/// IMK calls `deactivateServer` right after `commitComposition`. A commit that waits
/// for the server reply arrives after deactivation and used to be discarded, losing
/// the composition (for example the second half left after committing the first
/// clause). With no key event in flight, the displayed marked text is exactly what the
/// server would commit, so it is inserted immediately.
public enum CompositionCommitPlan: Equatable, Sendable {
    /// Insert this text now; the server is told to commit only for learning/cleanup.
    case insertDisplayedText(String)
    /// Nothing is displayed.
    case nothingToCommit
    /// Key events are still in flight; the displayed text may be stale, so ask the
    /// server and deliver its reply even if the client was deactivated meanwhile.
    case askServer

    public static func make(pendingKeyEvents: Int, displayed: ConverterSessionSnapshot?) -> Self {
        guard pendingKeyEvents == 0 else {
            return .askServer
        }
        guard let displayed else {
            return .nothingToCommit
        }
        let text = displayed.markedText.elements.map(\.content).joined()
        return text.isEmpty ? .nothingToCommit : .insertDisplayedText(text)
    }
}
