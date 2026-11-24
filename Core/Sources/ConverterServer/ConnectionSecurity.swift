import Foundation
import Security

/// Pin the exact signed host executable. An identifier alone is forgeable for
/// personal ad-hoc builds. XPC checks the requirement on every message.
enum ConnectionSecurity {
    static func requirement() -> String? {
        let executable: URL
        if ProcessInfo.processInfo.environment["TENARAI_TEST_ROOT"] != nil,
           let testClient = ProcessInfo.processInfo.environment["TENARAI_TEST_CLIENT"] {
            executable = URL(fileURLWithPath: testClient)
        } else {
            let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            executable = helper.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("MacOS/azooKeyMac")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }
}
