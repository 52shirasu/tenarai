import Carbon
import Foundation

// Installer operation only: register the installed bundle. Do not switch the
// user's current input source or remove/disable any existing source.
let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/tenarai-Dev.app").path
let status = TISRegisterInputSource(URL(fileURLWithPath: path) as CFURL)
print("TISRegisterInputSource status: \(status)")
let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
for source in sources {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
    let identifier = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    if identifier.hasPrefix("local.tenarai.inputmethod.tenarai") {
        print("registered source: \(identifier)")
        if identifier == "local.tenarai.inputmethod.tenarai" {
            print("TISEnableInputSource status: \(TISEnableInputSource(source))")
        }
        for key in [kTISPropertyLocalizedName, kTISPropertyInputSourceLanguages, kTISPropertyInputSourceIsEnableCapable, kTISPropertyInputSourceIsEnabled] {
            if let value = TISGetInputSourceProperty(source, key) {
                print("\(key!): \(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue())")
            }
        }
    }
}
if status != noErr { exit(1) }
