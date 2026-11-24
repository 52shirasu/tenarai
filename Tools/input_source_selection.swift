// Usage: input_source_selection.swift current | select <input source ID>
// The installer records the selected source before replacing the IME and puts the
// same one back afterwards: stopping the IME makes macOS fall back to another source.
import Carbon

func string(_ source: TISInputSource, _ key: CFString) -> String {
    guard let raw = TISGetInputSourceProperty(source, key) else { return "" }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

let arguments = CommandLine.arguments
switch arguments.count > 1 ? arguments[1] : "" {
case "current":
    print(string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID))
case "select" where arguments.count > 2:
    let filter = [kTISPropertyInputSourceID as String: arguments[2]] as CFDictionary
    guard let source = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first else {
        FileHandle.standardError.write(Data("input source not found\n".utf8)); exit(1)
    }
    exit(TISSelectInputSource(source) == noErr ? 0 : 1)
default:
    FileHandle.standardError.write(Data("usage: current | select <id>\n".utf8)); exit(2)
}
