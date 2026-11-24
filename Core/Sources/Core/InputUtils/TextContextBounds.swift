import Foundation

/// All offsets are UTF-16, as required by IMKTextInput. Never invent a cursor
/// at offset zero when the client cannot report its selection.
public enum TextContextBounds {
    public static func valid(_ range: NSRange, length: Int) -> Bool {
        length >= 0 && range.location != NSNotFound && range.location >= 0
            && range.length >= 0 && range.location <= length && range.length <= length - range.location
    }

    public static func surrounding(marked: NSRange, selected: NSRange, length: Int,
                                   limit: Int) -> (left: NSRange, right: NSRange)? {
        guard limit >= 0 else { return nil }
        let cursor = marked.location == NSNotFound ? selected : marked
        guard valid(cursor, length: length) else { return nil }
        let before = min(cursor.location, limit)
        let after = cursor.location + cursor.length
        return (NSRange(location: cursor.location - before, length: before),
                NSRange(location: after, length: min(length - after, limit)))
    }
}

/// A paste shortcut is only a hint. Learn text only after the host reports an
/// insertion consistent with that selection. No clipboard access is needed.
public struct PendingPaste: Sendable {
    public let selection: NSRange
    public let documentLength: Int
    public init?(selection: NSRange, documentLength: Int) {
        guard TextContextBounds.valid(selection, length: documentLength) else { return nil }
        self.selection = selection
        self.documentLength = documentLength
    }
    public func insertedRange(selection after: NSRange, documentLength: Int) -> NSRange? {
        guard TextContextBounds.valid(after, length: documentLength), after.length == 0,
              after.location > selection.location else { return nil }
        let count = after.location - selection.location
        guard documentLength >= count,
              documentLength - count == self.documentLength - selection.length else { return nil }
        return NSRange(location: selection.location, length: count)
    }
}

/// Distinguishes externally inserted text from unchanged/deleted text; never reads the clipboard.
public enum ExternalTextChange {
    public static func insertion(from old: String, to new: String) -> String? {
        guard old != new else { return nil }
        let prefix = zip(old, new).prefix { $0 == $1 }.count
        let oldTail = old.dropFirst(prefix), newTail = new.dropFirst(prefix)
        let suffix = zip(oldTail.reversed(), newTail.reversed()).prefix { $0 == $1 }.count
        let inserted = newTail.dropLast(suffix)
        return inserted.isEmpty ? nil : String(inserted.prefix(32768))
    }
}
