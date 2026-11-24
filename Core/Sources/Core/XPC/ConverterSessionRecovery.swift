/// Both the connection endpoint and the converter can reject a stale session.
/// Keep this narrow: permission, decoding and resource-limit errors are not
/// evidence that opening another session will repair the request.
public enum ConverterSessionRecovery {
    public static func requiresNewSession(_ error: String) -> Bool {
        error == "Unknown session" || error.hasPrefix("Unknown converter session:")
    }
}
