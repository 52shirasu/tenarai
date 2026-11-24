import Foundation

/// Password fields turn on Secure Event Input. While the app being typed into owns it,
/// keys go straight to the app: no composition, no marked text, no learning.
public enum SecureInputPolicy {
    /// - Parameters:
    ///   - secureInputEnabled: `IsSecureEventInputEnabled()`; true while any process has it on.
    ///   - ownerPID: the process that turned it on (`kCGSSessionSecureInputPID`), if known.
    ///   - clientPIDs: processes of the app being typed into, if known.
    /// Another app holding it (Terminal's Secure Keyboard Entry, a password manager)
    /// must not turn off Japanese input everywhere, so only the client's own counts.
    /// When either side is unknown, the field is treated as secure.
    public static func bypassesInputMethod(secureInputEnabled: Bool, ownerPID: Int32?, clientPIDs: [Int32]) -> Bool {
        guard secureInputEnabled else {
            return false
        }
        guard let ownerPID, !clientPIDs.isEmpty else {
            return true
        }
        return clientPIDs.contains(ownerPID)
    }
}
