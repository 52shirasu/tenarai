import Foundation
import Core

/// Pattern matrices for the October 2026 conversion/segment work.
/// Each mode prints one JSON object per line with a fixed prefix so the
/// Python driver can aggregate before/after runs with identical inputs.
@MainActor
final class MatrixClient {
    private let connection: NSXPCConnection
    let sessionID = UUID().uuidString
    private var eventID: UInt64 = 0

    init(serviceName: String) {
        connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ScenarioXPC.self)
        connection.resume()
    }

    func invalidate() { connection.invalidate() }

    func send(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
        let data = try ConverterServerCodec.encode(command)
        return try await withCheckedThrowingContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                continuation.resume(throwing: error)
            } as! ScenarioXPC
            proxy.handleCommand(data) { result, error in
                do {
                    guard let result else {
                        throw NSError(domain: "Matrix", code: 1, userInfo: [NSLocalizedDescriptionKey: error as String? ?? "missing response"])
                    }
                    continuation.resume(returning: try ConverterServerCodec.decodeResponse(from: result))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func open() async throws {
        _ = try await send(.openSession(sessionID: sessionID, command: .lifecycle(.activate)))
        // The app asks for this at launch; scenarios that need the compiled dictionary ask here.
        if ProcessInfo.processInfo.environment["TENARAI_SYNC_DICTIONARY"] == "1" {
            _ = try await send(.maintenance(.synchronizeUserDictionary(forceExport: false)))
        }
    }

    func command(_ value: ConverterSessionCommand) async throws -> ConverterServerResponse {
        try await send(.session(sessionID: sessionID, command: value))
    }

    private var serverLive: Bool?

    /// The server renders marked text from its own preference, so keep it equal to
    /// the per-event flag; otherwise a "live off" run is only half off.
    func syncLive(_ live: Bool) async throws {
        guard serverLive != live else { return }
        _ = try await command(.settings(.update(key: Config.LiveConversion.key, value: .bool(live))))
        serverLive = live
    }

    func key(_ key: MatrixKey, context: ConverterTextContext = .init(), live: Bool, visibleCandidateStartIndex: Int = 0) async throws -> ConverterServerResponse {
        try await syncLive(live)
        eventID += 1
        return try await command(.handleKeyEvent(.init(
            eventID: eventID,
            event: .init(modifierFlags: key.modifiers, characters: key.characters,
                         charactersIgnoringModifiers: key.characters.lowercased(), keyCode: key.code),
            inputStyle: .defaultRomanToKana, liveConversionEnabled: live, enableDebugWindow: false,
            enableSuggestion: false, context: context, activation: takeActivation(),
            visibleCandidateStartIndex: visibleCandidateStartIndex)))
    }

    /// Sent with the next key event, like the IME does after activateServer.
    var pendingActivation: ConverterSessionActivation?
    private func takeActivation() -> ConverterSessionActivation? {
        defer { pendingActivation = nil }
        return pendingActivation
    }
}

struct MatrixKey {
    var characters: String
    var code: UInt16
    var modifiers: KeyEventCore.ModifierFlag = []

    static func letter(_ c: Character) -> MatrixKey { .init(characters: String(c), code: 0) }
    static let space = MatrixKey(characters: " ", code: 49)
    static let enter = MatrixKey(characters: "\r", code: 36)
    static let escape = MatrixKey(characters: "\u{1b}", code: 53)
    static let backspace = MatrixKey(characters: "\u{7f}", code: 51)
    static let left = MatrixKey(characters: "\u{F702}", code: 123)
    static let right = MatrixKey(characters: "\u{F703}", code: 124)
    static let down = MatrixKey(characters: "\u{F701}", code: 125)
    static let up = MatrixKey(characters: "\u{F700}", code: 126)
    static let shiftLeft = MatrixKey(characters: "\u{F702}", code: 123, modifiers: [.shift])
    static let shiftRight = MatrixKey(characters: "\u{F703}", code: 124, modifiers: [.shift])
    static func number(_ n: Int) -> MatrixKey {
        let codes: [Int: UInt16] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23, 6: 22, 7: 26, 8: 28, 9: 25, 0: 29]
        return .init(characters: String(n), code: codes[n]!)
    }
}

/// One step of a segment scenario.
enum MatrixOp: String, CaseIterable {
    case space, enter, escape, backspace, right, down, up, shiftLeft, shiftRight
    case number1, number2, typeNi, commitComposition
}

struct SegmentPhrase {
    let segments: Int
    let raw: String
}

let segmentPhrases: [SegmentPhrase] = [
    .init(segments: 1, raw: "henkan"),
    .init(segments: 1, raw: "gohenkan"),
    .init(segments: 1, raw: "konnnichiha"),
    .init(segments: 2, raw: "gohenkangaooi"),
    .init(segments: 2, raw: "kyouhaame"),
    .init(segments: 2, raw: "minnnadeikou"),
    .init(segments: 3, raw: "watashihagakuseidesu"),
    .init(segments: 3, raw: "ashitahayamaninoboru"),
    .init(segments: 3, raw: "konnanikanntannidekiru"),
    .init(segments: 5, raw: "kyouhatenkigayoinodesanponiikimasu"),
    .init(segments: 5, raw: "sa-ba-nosetteiwokakuninshitekudasai"),
    .init(segments: 6, raw: "senngetsukattahonnwomadayondeinainndesu")
]

/// Operation sequences applied after the reading is typed. Anything left in
/// the composition afterwards is drained with Enter and then commitComposition.
let segmentOperations: [(name: String, ops: [MatrixOp])] = [
    ("enter", [.enter]),
    ("commitComposition", [.commitComposition]),
    ("space_enter", [.space, .enter]),
    ("space_enter_enter", [.space, .enter, .enter]),
    ("space_space_enter", [.space, .space, .enter]),
    ("space_space_space_enter", [.space, .space, .space, .enter]),
    ("space_right_enter", [.space, .right, .enter]),
    ("space_right_right_enter", [.space, .right, .right, .enter]),
    ("space_down_down_right_enter", [.space, .down, .down, .right, .enter]),
    ("space_number1", [.space, .number1]),
    ("space_number2_enter", [.space, .number2, .enter]),
    ("space_shiftLeft_enter", [.space, .shiftLeft, .enter]),
    ("space_shiftLeft_shiftLeft_right_enter", [.space, .shiftLeft, .shiftLeft, .right, .enter]),
    ("space_shiftRight_enter", [.space, .shiftRight, .enter]),
    ("space_shiftRight_shiftRight_right_enter", [.space, .shiftRight, .shiftRight, .right, .enter]),
    ("shiftLeft_enter", [.shiftLeft, .enter]),
    ("shiftRight_right_enter", [.shiftRight, .right, .enter]),
    ("space_enter_typeNi_enter", [.space, .enter, .typeNi, .enter]),
    ("space_typeNi_enter", [.space, .typeNi, .enter]),
    ("space_enter_commitComposition", [.space, .enter, .commitComposition]),
    ("space_shiftLeft_commitComposition", [.space, .shiftLeft, .commitComposition]),
    ("space_escape_enter", [.space, .escape, .enter]),
    ("space_escape_space_enter", [.space, .escape, .space, .enter]),
    ("backspace_enter", [.backspace, .enter]),
    ("space_backspace_enter", [.space, .backspace, .enter]),
    ("space_shiftLeft_backspace_enter", [.space, .shiftLeft, .backspace, .enter]),
    ("space_up_enter", [.space, .up, .enter]),
    ("escape", [.escape])
]

private extension ConverterServerResponse {
    var committedText: String {
        effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }.joined()
    }
    var markedString: String { snapshot.markedText.elements.map(\.content).joined() }
}

private func hiraganaOnly(_ text: String) -> [Character] {
    text.filter { $0.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || $0 == "ー" } }
}

private func isKanji(_ c: Character) -> Bool {
    c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || $0 == "々" }
}

/// Heuristic: can `text` plausibly be a rendering of `reading`?
/// Each kanji covers 1...4 reading characters; kana must appear in order.
func plausiblyCovers(_ text: String, reading: String) -> Bool {
    if text.isEmpty { return reading.isEmpty }
    let kana = hiraganaOnly(text)
    var iterator = Array(reading)[...]
    for c in kana {
        guard let index = iterator.firstIndex(of: c) else { return false }
        iterator = iterator[(index + 1)...]
    }
    let kanji = text.filter(isKanji).count
    let other = text.count - kana.count - kanji
    let maximum = kana.count + kanji * 4 + other * 4
    if reading.count > maximum { return false }
    if let last = text.last, hiraganaOnly(String(last)).count == 1, reading.last != last { return false }
    return true
}

enum Matrix {
    static func emit(_ prefix: String, _ row: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print(prefix + " " + String(data: data, encoding: .utf8)!)
        fflush(nil)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    // MARK: segment matrix
    @MainActor
    static func runSegments(_ client: MatrixClient) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
        var total = 0, lost = 0, mismatch = 0, errors = 0
        let typingModes = ["sequential", "afterPaste"]
        for phrase in segmentPhrases {
            for live in [true, false] {
                for typing in typingModes {
                    for operation in segmentOperations {
                        total += 1
                        var row: [String: Any] = ["raw": phrase.raw, "segments": phrase.segments, "live": live,
                                                  "typing": typing, "operation": operation.name]
                        do {
                            let result = try await runSegmentScenario(client, phrase: phrase, live: live, typing: typing, ops: operation.ops)
                            for (k, v) in result { row[k] = v }
                            if (result["lossEvents"] as? [[String: Any]])?.isEmpty == false { lost += 1 }
                            if (result["displayMismatch"] as? [[String: Any]])?.isEmpty == false { mismatch += 1 }
                        } catch {
                            errors += 1
                            row["error"] = String(describing: error)
                        }
                        emit("SEGMENT", row)
                    }
                }
            }
        }
        emit("SEGMENT_SUMMARY", ["total": total, "scenariosWithLoss": lost, "scenariosWithDisplayMismatch": mismatch, "errors": errors])
    }

    @MainActor
    static func runSegmentScenario(_ client: MatrixClient, phrase: SegmentPhrase, live: Bool, typing: String, ops: [MatrixOp]) async throws -> [String: Any] {
        _ = try await client.command(.composition(.stopComposition))
        if typing == "afterPaste" {
            _ = try await client.command(.learning(.observe(text: "貼り付けたテキスト", origin: .pasted)))
        }
        var last = try await client.command(.composition(.snapshot))
        var committedPieces: [String] = []
        var steps: [[String: Any]] = []
        var lossEvents: [[String: Any]] = []
        var displayMismatch: [[String: Any]] = []
        for c in phrase.raw {
            last = try await client.key(.letter(c), live: live)
            if !last.committedText.isEmpty { committedPieces.append(last.committedText) }
        }
        let fullReading = last.snapshot.convertTarget
        var allOps = ops
        // Drain: at most 8 Enter presses, then a final commitComposition.
        allOps += Array(repeating: .enter, count: 8)
        var drained = false
        for op in allOps {
            if op == .enter && drained { break }
            let before = last
            if before.snapshot.isEmpty && op == .enter && steps.count >= ops.count { break }
            let response: ConverterServerResponse
            switch op {
            case .space: response = try await client.key(.space, live: live)
            case .enter: response = try await client.key(.enter, live: live)
            case .escape: response = try await client.key(.escape, live: live)
            case .backspace: response = try await client.key(.backspace, live: live)
            case .right: response = try await client.key(.right, live: live)
            case .down: response = try await client.key(.down, live: live)
            case .up: response = try await client.key(.up, live: live)
            case .shiftLeft: response = try await client.key(.shiftLeft, live: live)
            case .shiftRight: response = try await client.key(.shiftRight, live: live)
            case .number1: response = try await client.key(.number(1), live: live)
            case .number2: response = try await client.key(.number(2), live: live)
            case .typeNi:
                _ = try await client.key(.letter("n"), live: live)
                response = try await client.key(.letter("i"), live: live)
            case .commitComposition: response = try await client.command(.composition(.commit))
            }
            let committed = response.committedText
            if !committed.isEmpty { committedPieces.append(committed) }
            let beforeReading = before.snapshot.convertTarget
            let afterReading = response.snapshot.convertTarget
            var step: [String: Any] = ["op": op.rawValue, "beforeMarked": before.markedString, "beforeReading": beforeReading,
                                       "committed": committed, "afterMarked": response.markedString, "afterReading": afterReading,
                                       "state": String(describing: response.inputState)]
            if !committed.isEmpty && op != .typeNi {
                // Reading consumed by this commit must be a prefix of the reading before it.
                let consumedOK = beforeReading.hasSuffix(afterReading)
                let consumed = consumedOK ? String(beforeReading.dropLast(afterReading.count)) : beforeReading
                step["consumed"] = consumed
                // Whole-text commit: inserted text must equal what the user saw.
                if response.snapshot.isEmpty, [.enter, .commitComposition].contains(op),
                   before.markedString != committed,
                   before.snapshot.markedText.elements.count == 1 {
                    displayMismatch.append(["op": op.rawValue, "shown": before.markedString, "inserted": committed])
                }
                // Prefix submission in selecting: the remainder must be the unfocused reading.
                let elements = before.snapshot.markedText.elements
                if elements.count == 2, elements[0].focus == .focused, committed == elements[0].content,
                   afterReading != elements[1].content {
                    lossEvents.append(["kind": "remainderChanged", "op": op.rawValue, "expectedRemainder": elements[1].content,
                                       "actualRemainder": afterReading, "committed": committed])
                }
                if !consumedOK || !plausiblyCovers(committed, reading: consumed) {
                    lossEvents.append(["kind": "readingNotCovered", "op": op.rawValue, "committed": committed,
                                       "consumedReading": consumed, "before": beforeReading, "after": afterReading])
                }
            } else if committed.isEmpty, op != .backspace, op != .escape, op != .typeNi,
                      !beforeReading.isEmpty, afterReading.isEmpty, before.snapshot.isEmpty == false {
                lossEvents.append(["kind": "vanishedWithoutCommit", "op": op.rawValue, "before": beforeReading])
            }
            steps.append(step)
            last = response
            if response.snapshot.isEmpty && steps.count >= ops.count { drained = true }
        }
        var leftover = ""
        if !last.snapshot.isEmpty {
            leftover = last.snapshot.convertTarget
            let flushed = try await client.command(.composition(.commit))
            if !flushed.committedText.isEmpty { committedPieces.append(flushed.committedText) }
        }
        return ["fullReading": fullReading, "committed": committedPieces, "steps": steps,
                "lossEvents": lossEvents, "displayMismatch": displayMismatch, "leftoverAfterDrain": leftover]
    }

    // MARK: accuracy matrix
    @MainActor
    static func runAccuracy(_ client: MatrixClient, learningLabel: String) async throws {
        // Measurement never commits, so cases cannot teach each other.
        let filter = ProcessInfo.processInfo.environment["TENARAI_ACCURACY_FILTER"].map { $0.split(separator: ",").map(String.init) }
        for (caseID, item) in accuracyCases.enumerated() {
            if let filter, !filter.contains(item.raw) { continue }
            for live in [true, false] {
                for mode in ["none", "left", "right", "both", "unrelated"] {
                    _ = try await client.command(.composition(.stopComposition))
                    let context = ConverterTextContext(
                        leftSideContext: mode == "unrelated" ? "今日は公園で花を見ました。" : (["left", "both"].contains(mode) ? item.left : ""),
                        rightSideContext: ["right", "both"].contains(mode) ? item.right : "")
                    var last: ConverterServerResponse?
                    var keyMs: [Double] = []
                    for c in item.raw {
                        let start = Date()
                        last = try await client.key(.letter(c), context: context, live: live)
                        keyMs.append(Date().timeIntervalSince(start) * 1000)
                    }
                    let liveText = last?.markedString ?? ""
                    let start = Date()
                    var opened = try await client.key(.space, context: context, live: live)
                    if !live { opened = try await client.key(.space, context: context, live: live) }
                    let spaceMs = Date().timeIntervalSince(start) * 1000
                    var texts: [String] = []
                    if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
                    let rank = texts.firstIndex(of: item.expected).map { $0 + 1 } ?? 0
                    emit("ACCURACY", ["id": caseID, "category": item.category, "raw": item.raw, "expected": item.expected,
                                      "mode": mode, "live": live, "learning": learningLabel, "rank": rank,
                                      "top9": Array(texts.prefix(9)), "liveText": liveText,
                                      "liveExact": live ? (liveText == item.expected) : NSNull(),
                                      "key_ms": keyMs, "space_ms": spaceMs])
                }
            }
        }
        _ = try await client.command(.composition(.stopComposition))
    }

    // MARK: performance matrix
    @MainActor
    static func runPerformance(_ client: MatrixClient) async throws {
        // TENARAI_PERF_LEARNING=1 measures with learning on, as in real use (some
        // converter caches only apply when learning is off).
        let learning = ProcessInfo.processInfo.environment["TENARAI_PERF_LEARNING"] == "1" ? "inputAndOutput" : "nothing"
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string(learning))))
        var first = true
        for round in 0..<4 {
            for (label, raw) in performanceInputs {
                for live in [true, false] {
                    _ = try await client.command(.composition(.stopComposition))
                    var keyMs: [Double] = []
                    for c in raw {
                        let start = Date()
                        _ = try await client.key(.letter(c), live: live)
                        keyMs.append(Date().timeIntervalSince(start) * 1000)
                    }
                    let start = Date()
                    let opened = try await client.key(.space, live: live)
                    let spaceMs = Date().timeIntervalSince(start) * 1000
                    let reading = opened.snapshot.convertTarget
                    _ = try await client.command(.composition(.stopComposition))
                    emit("PERF", ["phase": first ? "cold" : "warm", "round": round, "length": label, "readingCount": reading.count,
                                  "live": live, "key_ms": keyMs, "space_ms": spaceMs,
                                  "key_p50": percentile(keyMs, 0.5), "key_p95": percentile(keyMs, 0.95), "key_max": keyMs.max() ?? 0])
                    first = false
                }
            }
        }
    }

    // MARK: soak
    @MainActor
    static func runSoak(_ client: MatrixClient, keys targetKeys: Int) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
        let sentences = soakInputs
        // Optional real-time pacing so memory is observed over the wall-clock duration too.
        let intervalMs = Int(ProcessInfo.processInfo.environment["TENARAI_SOAK_INTERVAL_MS"] ?? "0") ?? 0
        var sent = 0, bucket: [Double] = [], bucketIndex = 0
        var failures = 0
        let started = Date()
        while sent < targetKeys {
            for raw in sentences {
                _ = try await client.command(.composition(.stopComposition))
                for c in raw {
                    let start = Date()
                    let r = try await client.key(.letter(c), live: true)
                    bucket.append(Date().timeIntervalSince(start) * 1000)
                    if r.effects.contains(where: { if case .insertText = $0 { return true }; return false }) { failures += 1 }
                    sent += 1
                    if intervalMs > 0 { try await Task.sleep(for: .milliseconds(intervalMs)) }
                }
                _ = try await client.key(.space, live: true)
                let done = try await client.key(.enter, live: true)
                if done.committedText.isEmpty { failures += 1 }
                let tail = try await client.command(.composition(.commit))
                _ = tail
                if bucket.count >= 500 {
                    emit("SOAK", ["bucket": bucketIndex, "keys": sent, "elapsed_s": Date().timeIntervalSince(started),
                                  "p50": percentile(bucket, 0.5), "p95": percentile(bucket, 0.95), "max": bucket.max() ?? 0,
                                  "failures": failures])
                    bucket.removeAll()
                    bucketIndex += 1
                }
                if sent >= targetKeys { break }
            }
        }
        emit("SOAK_DONE", ["keys": sent, "elapsed_s": Date().timeIntervalSince(started), "failures": failures])
    }

    // MARK: fault injection with the real IME client
    static func helperPID(label: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") { return Int32(trimmed.dropFirst(6)) }
        }
        return nil
    }

    /// Mirrors the input controller: replies replace the displayed view, inserted text
    /// is collected, and a replaced session commits what was displayed.
    @MainActor
    static func runFaultMatrix(serviceName: String, label: String) async throws {
        let reading = "ごへんかんがおおい"
        let romaji = Array("gohenkangaooi")
        for fault in ["none", "kill", "freeze1500ms", "shutdown", "killTwice"] {
            for faultAfter in [4, 9] {
                // The helper may still be respawning after the previous kill.
                for attempt in 0..<40 {
                    let settings = MatrixClient(serviceName: serviceName)
                    defer { settings.invalidate() }
                    do {
                        try await settings.open()
                        try await settings.syncLive(false)
                        break
                    } catch where attempt < 39 {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                }
                let client = ConverterServerClient(machServiceName: serviceName)
                var view: ConverterSessionSnapshot?
                var inserted: [String] = []
                var replaced = 0
                let legacy = ProcessInfo.processInfo.environment["TENARAI_FAULT_LEGACY"] == "1"
                client.onSessionReplaced = {
                    replaced += 1
                    // The pre-fix controller ignored the replacement; the next reply overwrote the view.
                    if legacy { return }
                    if let view { inserted.append(view.markedText.elements.map(\.content).joined()) }
                    view = nil
                }
                func apply(_ response: ConverterServerResponse?) {
                    guard let response else { return }
                    for case .insertText(let text) in response.effects { inserted.append(text) }
                    view = response.snapshot.isEmpty ? nil : response.snapshot
                }
                var eventID: UInt64 = 0
                func key(_ key: MatrixKey) async -> ConverterServerResponse? {
                    eventID += 1
                    let request = ConverterKeyEventRequest(
                        eventID: eventID,
                        event: .init(modifierFlags: key.modifiers, characters: key.characters,
                                     charactersIgnoringModifiers: key.characters.lowercased(), keyCode: key.code),
                        inputStyle: .defaultRomanToKana, liveConversionEnabled: false, enableDebugWindow: false,
                        enableSuggestion: false, context: .init())
                    return await withCheckedContinuation { continuation in
                        client.sendKeyEvent(request) { continuation.resume(returning: $0) }
                    }
                }
                let started = Date()
                var stalls: [Double] = []
                for (index, character) in romaji.enumerated() {
                    if index == faultAfter {
                        switch fault {
                        case "kill", "killTwice":
                            if let pid = helperPID(label: label) { kill(pid, SIGKILL) }
                            if fault == "killTwice" {
                                try await Task.sleep(for: .milliseconds(300))
                                if let pid = helperPID(label: label) { kill(pid, SIGKILL) }
                            }
                        case "freeze1500ms":
                            if let pid = helperPID(label: label) {
                                kill(pid, SIGSTOP)
                                Task.detached { try? await Task.sleep(for: .milliseconds(1500)); kill(pid, SIGCONT) }
                            }
                        case "shutdown":
                            await withCheckedContinuation { continuation in
                                client.restartServer { _ in continuation.resume() }
                            }
                        default:
                            break
                        }
                    }
                    let keyStart = Date()
                    apply(await key(.letter(character)))
                    stalls.append(Date().timeIntervalSince(keyStart) * 1000)
                }
                apply(await key(.enter))
                let final = inserted.joined() + (view?.markedText.elements.map(\.content).joined() ?? "")
                emit("FAULT", ["fault": fault, "faultAfterKeys": faultAfter, "inserted": inserted, "final": final,
                               "expected": reading, "lost": final != reading, "sessionReplaced": replaced,
                               "maxKeyMs": stalls.max() ?? 0, "elapsed_s": Date().timeIntervalSince(started)])
                client.closeSession()
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }
}

struct AccuracyCase {
    let category: String
    let raw: String
    let left: String
    let right: String
    let expected: String
}

// Synthetic sentences only; nothing copied from the user's documents.
let accuracyCases: [AccuracyCase] = [
    // 同音異義語
    .init(category: "同音異義語", raw: "gohenkan", left: "入力中の", right: "が多くて困る", expected: "誤変換"),
    .init(category: "同音異義語", raw: "gohenkangaooi", left: "最近", right: "ので困っている", expected: "誤変換が多い"),
    .init(category: "同音異義語", raw: "haisuikou", left: "台所の", right: "が詰まった", expected: "排水口"),
    .init(category: "同音異義語", raw: "haisuikou", left: "道路脇の", right: "に落ち葉がたまる", expected: "排水溝"),
    .init(category: "同音異義語", raw: "igai", left: "それ", right: "の方法はない", expected: "以外"),
    .init(category: "同音異義語", raw: "igai", left: "結果は", right: "なものだった", expected: "意外"),
    .init(category: "同音異義語", raw: "kanshin", left: "政治に", right: "がある", expected: "関心"),
    .init(category: "同音異義語", raw: "kanshin", left: "その努力には", right: "した", expected: "感心"),
    .init(category: "同音異義語", raw: "hoshou", left: "製品の", right: "期間", expected: "保証"),
    .init(category: "同音異義語", raw: "hoshou", left: "損害を", right: "する", expected: "補償"),
    .init(category: "同音異義語", raw: "taishou", left: "調査の", right: "となる人", expected: "対象"),
    .init(category: "同音異義語", raw: "taishou", left: "左右", right: "の図形", expected: "対称"),
    // 接頭辞
    .init(category: "接頭辞", raw: "gorenraku", left: "", right: "ください", expected: "ご連絡"),
    .init(category: "接頭辞", raw: "gokakunin", left: "資料を", right: "ください", expected: "ご確認"),
    .init(category: "接頭辞", raw: "gosetsumei", left: "詳しく", right: "します", expected: "ご説明"),
    .init(category: "接頭辞", raw: "otegami", left: "先日の", right: "ありがとうございます", expected: "お手紙"),
    .init(category: "接頭辞", raw: "oshirase", left: "メンテナンスの", right: "です", expected: "お知らせ"),
    .init(category: "接頭辞", raw: "gosousa", left: "画面の", right: "に注意", expected: "誤操作"),
    .init(category: "接頭辞", raw: "gohandan", left: "その", right: "が原因だった", expected: "誤判断"),
    // 固有名詞
    .init(category: "固有名詞", raw: "toukyoueki", left: "", right: "で待ち合わせ", expected: "東京駅"),
    .init(category: "固有名詞", raw: "oosaka", left: "週末は", right: "に行く", expected: "大阪"),
    .init(category: "固有名詞", raw: "fujisan", left: "晴れた日に", right: "が見える", expected: "富士山"),
    .init(category: "固有名詞", raw: "kyouto", left: "修学旅行で", right: "へ行った", expected: "京都"),
    .init(category: "固有名詞", raw: "hokkaidou", left: "冬の", right: "は寒い", expected: "北海道"),
    // カタカナ語
    .init(category: "カタカナ語", raw: "sa-ba-", left: "Dockerの", right: "を再起動する", expected: "サーバー"),
    .init(category: "カタカナ語", raw: "deta-be-su", left: "", right: "に保存する", expected: "データベース"),
    .init(category: "カタカナ語", raw: "apurike-shon", left: "スマホの", right: "を更新する", expected: "アプリケーション"),
    .init(category: "カタカナ語", raw: "baggu", left: "プログラムの", right: "を直す", expected: "バグ"),
    .init(category: "カタカナ語", raw: "kontena", left: "Dockerの", right: "を起動する", expected: "コンテナ"),
    // 数字・日付
    .init(category: "数字・日付", raw: "3gatsu15nichi", left: "", right: "に提出", expected: "3月15日"),
    .init(category: "数字・日付", raw: "10ji30pun", left: "明日の", right: "から会議", expected: "10時30分"),
    .init(category: "数字・日付", raw: "2kai", left: "1日", right: "飲む", expected: "2回"),
    .init(category: "数字・日付", raw: "5nin", left: "参加者は", right: "です", expected: "5人"),
    .init(category: "数字・日付", raw: "100en", left: "値段は", right: "です", expected: "100円"),
    // 口語・関西弁
    .init(category: "口語・関西弁", raw: "nanishitennen", left: "", right: "", expected: "何してんねん"),
    .init(category: "口語・関西弁", raw: "honmaniomoroi", left: "", right: "", expected: "ほんまにおもろい"),
    .init(category: "口語・関西弁", raw: "ookini", left: "", right: "", expected: "おおきに"),
    .init(category: "口語・関西弁", raw: "yabaine", left: "それ", right: "", expected: "やばいね"),
    .init(category: "口語・関西弁", raw: "chottomattete", left: "", right: "すぐ行く", expected: "ちょっと待ってて"),
    // 長文
    .init(category: "長文", raw: "kyouhatenkigayoinodekouenwosanposhitekaradenshadekaisyanimukaimasu", left: "", right: "", expected: "今日は天気が良いので公園を散歩してから電車で会社に向かいます"),
    .init(category: "長文", raw: "sa-ba-nosetteiwohenkoushitaatohakanarazusaikidoushitedousawokakuninshitekudasai", left: "", right: "", expected: "サーバーの設定を変更した後は必ず再起動して動作を確認してください"),
    .init(category: "長文", raw: "senshuukattahonwomadasaigomadeyondeinainodekonshuumatsuniyomitaidesu", left: "", right: "", expected: "先週買った本をまだ最後まで読んでいないので今週末に読みたいです"),
    .init(category: "長文", raw: "gohenkangaooikotonitsuitegeninwoshirabetekaizenshitaitoomoimasu", left: "", right: "", expected: "誤変換が多いことについて原因を調べて改善したいと思います"),
    .init(category: "長文", raw: "ashitanokaigideha2026nendonoyosannnituitehanashiaimasu", left: "", right: "", expected: "明日の会議では2026年度の予算について話し合います"),
    // 短文
    .init(category: "短文", raw: "henkan", left: "", right: "", expected: "変換"),
    .init(category: "短文", raw: "kaigi", left: "", right: "", expected: "会議"),
    .init(category: "短文", raw: "ryoukai", left: "", right: "", expected: "了解"),
    .init(category: "短文", raw: "arigatou", left: "", right: "", expected: "ありがとう"),
    .init(category: "短文", raw: "kakunin", left: "", right: "", expected: "確認")
]

let performanceInputs: [(String, String)] = [
    ("5", "henkanwo"),
    ("20", "kyouhatenkigayoinodesanponiikimasu"),
    ("50", "sa-ba-nosetteiwohenkoushitaatohakanarazusaikidoushitedousawokakuninshitekudasaimatahenkouno"),
    ("100", "kyouhatenkigayoinodekouenwosanposhitekaradenshadekaisyanimukaimasusa-ba-nosetteiwohenkoushitaatohakanarazusaikidoushitedousawokakuninshitekudasaisenshuukattahonwomadasaigomade")
]

let soakInputs: [String] = [
    "kyouhatenkigayoinodesanponiikimasu", "sa-ba-nosetteiwokakuninshimasu", "gohenkangaooi",
    "ashitanokaigiha10jikaradesu", "arigatougozaimasu", "konnanikanntannidekiru", "nanishitennen"
]

// MARK: far-context and profile sets (2026-10-05)
/// The deciding sentence is placed far from the cursor with neutral filler between,
/// so only a model that sees beyond the nearest characters can resolve the homophone.
let farContextFiller = "その日は朝から雨が降っていて、出かけるのが少し億劫だった。昼過ぎにようやく晴れてきたので、近所を少し歩いてから家に戻ってきた。"
let farContextCases: [(far: String, raw: String, expected: String)] = [
    ("キッチンの水回りを掃除していた。", "haisuikou", "排水口"), ("道路の側溝に落ち葉がたまっていた。", "haisuikou", "排水溝"),
    ("プログラムのコードレビューで指摘を受けた。", "kansuu", "関数"), ("集めている漫画の単行本が増えてきた。", "kansuu", "巻数"),
    ("工場の生産ラインを見学した。", "kikai", "機械"), ("久しぶりに昔の友人と話をした。", "kikai", "機会"),
    ("新しいAPIの設計書をまとめている。", "shiyou", "仕様"), ("薬の説明書を読み直した。", "shiyou", "使用"),
    ("警察が事件の犯人を追っている。", "sousa", "捜査"), ("スマホのアプリの画面を触っていた。", "sousa", "操作"),
    ("ブログの記事を書いている。", "koushin", "更新"), ("運動会の練習をしていた。", "koushin", "行進"),
    ("家電を買ったときの書類を探していた。", "hoshou", "保証"), ("交通事故の損害について話し合った。", "hoshou", "補償"),
    ("試験問題を最後まで解いた。", "kaitou", "解答"), ("冷凍庫から肉を出しておいた。", "kaitou", "解凍"),
    ("マラソン大会に出場した。", "kyousou", "競走"), ("企業同士がシェアを奪い合っている。", "kyousou", "競争"),
    ("新聞社に就職が決まった。", "kisha", "記者"), ("鉄道の旅を楽しんだ。", "kisha", "汽車")
]
/// No context: only the learned profile can tilt these toward the user's field.
let profileCases: [(raw: String, expected: String)] = [
    ("kansuu", "関数"), ("shiyou", "仕様"), ("henkan", "変換"), ("kouzou", "構造"), ("jissou", "実装"),
    ("kiban", "基盤"), ("seigyo", "制御"), ("kidou", "起動"), ("teigi", "定義"), ("hensuu", "変数"),
    ("kankyou", "環境"), ("ninshou", "認証")
]

extension Matrix {
    @MainActor
    static func runContextSets(_ client: MatrixClient, label: String) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
        func rank(_ raw: String, _ expected: String, _ context: ConverterTextContext, live: Bool) async throws -> (Int, [String]) {
            _ = try await client.command(.composition(.stopComposition))
            for c in raw { _ = try await client.key(.letter(c), context: context, live: live) }
            var opened = try await client.key(.space, context: context, live: live)
            if !live { opened = try await client.key(.space, context: context, live: live) }
            var texts: [String] = []
            if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
            _ = try await client.command(.composition(.stopComposition))
            return ((texts.firstIndex(of: expected).map { $0 + 1 } ?? 0), Array(texts.prefix(5)))
        }
        let near = "そういえば、"
        let right = "のことが気になった。"
        for (id, item) in farContextCases.enumerated() {
            for live in [true, false] {
                for mode in ["none", "nearOnly", "far130", "far300"] {
                    let left: String = switch mode {
                    case "none": ""
                    case "nearOnly": farContextFiller + farContextFiller + near
                    case "far130": item.far + farContextFiller + farContextFiller + near
                    default: item.far + String(repeating: farContextFiller, count: 4) + near
                    }
                    let context = ConverterTextContext(leftSideContext: left, rightSideContext: mode == "none" ? "" : right)
                    let (r, top) = try await rank(item.raw, item.expected, context, live: live)
                    emit("FARCTX", ["id": id, "raw": item.raw, "expected": item.expected, "mode": mode, "live": live,
                                    "rank": r, "top5": top, "leftCount": left.count, "label": label])
                }
            }
        }
        // Profile cases use the learned tendencies, so learning must be on.
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        for item in profileCases {
            for live in [true, false] {
                let (r, top) = try await rank(item.raw, item.expected, .init(), live: live)
                emit("PROFILE", ["raw": item.raw, "expected": item.expected, "live": live, "rank": r, "top5": top, "label": label])
            }
        }
        // Standard romaji: nn is ん, so these must reach the intended words.
        for (raw, expected) in [("hannei", "反映"), ("konnnichiha", "こんにちは"), ("kinnenn", "禁煙")] {
            for live in [true, false] {
                let (r, top) = try await rank(raw, expected, .init(), live: live)
                emit("ROMAJI", ["raw": raw, "expected": expected, "live": live, "rank": r, "top5": top, "label": label])
            }
        }
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
    }
}

// MARK: style (tone/dialect) set (2026-10-05)
let styleCases: [(group: String, context: String, raw: String, expected: String)] = {
    let kansai = "そんなん言われても困るわ、"
    let polite = "いつもお世話になっております。先日の件について、"
    let casual = "昨日のライブ最高だった笑 てか、"
    return [
        ("関西弁", kansai, "honmani", "ほんまに"), ("関西弁", kansai, "akan", "あかん"), ("関西弁", kansai, "nannyanenn", "なんやねん"),
        ("関西弁", kansai, "ikahen", "行かへん"), ("関西弁", kansai, "shiran", "知らん"), ("関西弁", kansai, "chaunen", "ちゃうねん"),
        ("関西弁", kansai, "dekihen", "できへん"), ("関西弁", kansai, "sounan", "そうなん"), ("関西弁", kansai, "meccha", "めっちゃ"),
        ("関西弁", kansai, "okan", "おかん"), ("関西弁", kansai, "nanbo", "なんぼ"), ("関西弁", kansai, "kamahen", "かまへん"),
        ("関西弁", kansai, "ikan", "行かん"), ("関西弁", kansai, "yarona", "やろな"), ("関西弁", kansai, "ittenn", "言ってん"),
        ("関西弁", kansai, "chau", "ちゃう"), ("関西弁", kansai, "hondena", "ほんでな"), ("関西弁", kansai, "sondena", "そんでな"),
        ("関西弁", kansai, "kanawann", "かなわん"), ("関西弁", kansai, "shindoi", "しんどい"), ("関西弁", kansai, "omoroi", "おもろい"),
        ("関西弁", kansai, "sayana", "せやな"), ("関西弁", kansai, "dekinn", "できん"), ("関西弁", kansai, "iwann", "言わん"),
        ("関西弁", kansai, "hottoite", "ほっといて"), ("関西弁", kansai, "nanshitenn", "何してん"), ("関西弁", kansai, "hayou", "早う"),
        ("関西弁", kansai, "youkaran", "よう分からん"), ("関西弁", kansai, "dekihennkatta", "できへんかった"), ("関西弁", kansai, "ikahennkara", "行かへんから"),
        ("丁寧", polite, "kudasai", "ください"), ("丁寧", polite, "itashimasu", "いたします"),
        ("丁寧", polite, "yoroshikuonegaiitashimasu", "よろしくお願いいたします"), ("丁寧", polite, "onegaimoushiagemasu", "お願い申し上げます"),
        ("丁寧", polite, "ukagaimasu", "伺います"), ("丁寧", polite, "mairimasu", "参ります"), ("丁寧", polite, "zonjimasu", "存じます"),
        ("丁寧", polite, "goshoutai", "ご招待"),
        ("くだけた", casual, "mazide", "マジで"), ("くだけた", casual, "yabai", "やばい"), ("くだけた", casual, "sugee", "すげえ"),
        ("くだけた", casual, "uketa", "ウケた"), ("くだけた", casual, "dekkai", "でっかい"), ("くだけた", casual, "bimyou", "微妙"),
        ("くだけた", casual, "wakaru", "わかる"), ("くだけた", casual, "kanben", "勘弁")
    ]
}()

extension Matrix {
    @MainActor
    static func runStyleSet(_ client: MatrixClient, label: String) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
        for item in styleCases {
            for live in [true, false] {
                for mode in ["none", "styled"] {
                    let context = ConverterTextContext(leftSideContext: mode == "none" ? "" : item.context, rightSideContext: "")
                    _ = try await client.command(.composition(.stopComposition))
                    var last: ConverterServerResponse?
                    for c in item.raw { last = try await client.key(.letter(c), context: context, live: live) }
                    let liveText = last?.snapshot.markedText.elements.map(\.content).joined() ?? ""
                    var opened = try await client.key(.space, context: context, live: live)
                    if !live { opened = try await client.key(.space, context: context, live: live) }
                    var texts: [String] = []
                    if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
                    _ = try await client.command(.composition(.stopComposition))
                    emit("STYLE", ["group": item.group, "raw": item.raw, "expected": item.expected, "mode": mode, "live": live,
                                   "rank": texts.firstIndex(of: item.expected).map { $0 + 1 } ?? 0, "top5": Array(texts.prefix(5)),
                                   "liveText": liveText, "label": label])
                }
            }
        }
    }
}

extension Matrix {
    /// End-to-end: tone learned from typing in one app is used for empty fields there.
    @MainActor
    static func runToneLearning(serviceName: String) async throws {
        func session(app: String) async throws -> MatrixClient {
            let client = MatrixClient(serviceName: serviceName)
            try await client.open()
            client.pendingActivation = .init(
                config: .init(aiBackendPreference: .off, openAIModelName: "", openAIEndpoint: "",
                              openAIAPIKey: .init(""), includeContextInAITransform: false),
                inputLanguage: .japanese, clientIdentifier: app)
            return client
        }
        func measure(_ client: MatrixClient, phase: String, app: String) async throws {
            for item in styleCases {
                for live in [true, false] {
                    _ = try await client.command(.composition(.stopComposition))
                    for c in item.raw { _ = try await client.key(.letter(c), live: live) }
                    var opened = try await client.key(.space, live: live)
                    if !live { opened = try await client.key(.space, live: live) }
                    var texts: [String] = []
                    if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
                    _ = try await client.command(.composition(.stopComposition))
                    emit("TONE", ["phase": phase, "app": app, "group": item.group, "raw": item.raw, "expected": item.expected,
                                  "live": live, "rank": texts.firstIndex(of: item.expected).map { $0 + 1 } ?? 0, "top5": Array(texts.prefix(5))])
                }
            }
        }
        let chat = try await session(app: "test.chat")
        _ = try await chat.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        _ = try await chat.command(.learning(.deleteAll))
        try await measure(chat, phase: "beforeLearning", app: "test.chat")
        // Realistic history: mostly standard technical writing, so the vocabulary
        // profile is technical and does not itself carry Kansai words.
        if ProcessInfo.processInfo.environment["TENARAI_TONE_MIXED_HISTORY"] == "1" {
            let technical = ["サーバーの設定を変更しました", "Dockerのコンテナを再起動する", "データベースのバックアップを確認",
                             "APIの仕様を確認してください", "ログを調査して原因を特定する", "デプロイの手順を整理した",
                             "ネットワークの設定を見直す", "テストを追加して実装を修正", "LLMの推論速度を計測した",
                             "ストレージの容量を増やした"]
            for _ in 0..<3 {
                for text in technical {
                    _ = try await chat.command(.learning(.observe(text: text, origin: .typed)))
                    // Real commits are seconds apart; the service drops bursts beyond 16 in flight.
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
        }
        for text in ["今日は行かへんわ", "ほんまにそうやねん", "それ知らんかったやん", "めっちゃ眠いわ", "なんでやねん、ちゃうやろ"] {
            _ = try await chat.command(.learning(.observe(text: text, origin: .typed)))
            try await Task.sleep(for: .milliseconds(40))
        }
        let mail = try await session(app: "test.mail")
        // The IME sends the app identifier with the first key event, before any commit.
        _ = try await mail.key(.letter("a"), live: true)
        _ = try await mail.command(.composition(.stopComposition))
        for text in ["ご確認をお願いいたします。", "承知しました。", "よろしくお願いいたします。", "資料をお送りします。", "ご連絡ありがとうございます。"] {
            _ = try await mail.command(.learning(.observe(text: text, origin: .typed)))
            try await Task.sleep(for: .milliseconds(40))
        }
        var learned: [LocalTendency] = []
        for _ in 0..<100 {
            learned = try await chat.command(.learning(.list)).localTendencies ?? []
            if learned.contains(where: { $0.key == "tone:test.chat:関西弁" && $0.evidence >= 3 }),
               learned.contains(where: { $0.key == "tone:test.mail:敬体" && $0.evidence >= 3 }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        emit("TONE_LEARNED", ["tones": learned.filter { $0.kind == .tone }.map { "\($0.key)=\($0.evidence)" }])
        // Tendencies are refreshed into the server's cache asynchronously; new sessions read them at composition start.
        try await Task.sleep(for: .milliseconds(200))
        try await measure(try await session(app: "test.chat"), phase: "afterLearning", app: "test.chat")
        try await measure(try await session(app: "test.mail"), phase: "afterLearning", app: "test.mail")
        _ = try await chat.command(.learning(.deleteAll))
    }
}

// MARK: personal language model (2026-10-05)
/// Unseen sentences; the persona corpus consistently writes the kanji forms.
let personaCases: [(raw: String, persona: String)] = [
    ("kyouhakaigigadekinai", "今日は会議が出来ない"), ("kakuninshitekudasai", "確認して下さい"),
    ("yoroshikuonegaiitashimasu", "宜しくお願い致します"), ("okaeshiitashimasu", "お返し致します"),
    ("shiryouwoitadaita", "資料を頂いた"), ("sonnakotogaatta", "そんな事があった"),
    ("kaerutokini", "帰る時に"), ("iroirotameshita", "色々試した"), ("takusanaru", "沢山ある"),
    ("hotondoowatta", "殆ど終わった"), ("dekirukadouka", "出来るかどうか"), ("oshietekudasai", "教えて下さい")
]

extension Matrix {
    @MainActor
    static func runPersonaSet(_ client: MatrixClient, label: String) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
        for item in personaCases {
            for live in [true, false] {
                _ = try await client.command(.composition(.stopComposition))
                var last: ConverterServerResponse?
                for c in item.raw { last = try await client.key(.letter(c), live: live) }
                let liveText = last?.snapshot.markedText.elements.map(\.content).joined() ?? ""
                var opened = try await client.key(.space, live: live)
                if !live { opened = try await client.key(.space, live: live) }
                var texts: [String] = []
                if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
                _ = try await client.command(.composition(.stopComposition))
                emit("PERSONA", ["raw": item.raw, "expected": item.persona, "live": live, "liveText": liveText,
                                 "rank": texts.firstIndex(of: item.persona).map { $0 + 1 } ?? 0, "top3": Array(texts.prefix(3)), "label": label])
            }
        }
    }
}

extension Matrix {
    /// End-to-end: committed sentences reach the corpus, the server rebuilds the model in
    /// the background, and later conversions use it at the default strength.
    @MainActor
    static func runPersonalModelEndToEnd(_ client: MatrixClient, corpus: [String]) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        try await runPersonaSet(client, label: "beforeLearning")
        // runPersonaSet turns learning off for its measurement; collection needs it on.
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        for line in corpus {
            // Commit each sentence as clause fragments, like partial commits in real use.
            var fragments: [String] = []
            var current = ""
            for character in line {
                current.append(character)
                if "はがをにでとのも".contains(character) && current.count >= 3 { fragments.append(current); current = "" }
            }
            if !current.isEmpty { fragments.append(current) }
            for fragment in fragments {
                _ = try await client.command(.learning(.observe(text: fragment, origin: .typed)))
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(Int(ProcessInfo.processInfo.environment["TENARAI_P13N_SENTENCE_GAP_MS"] ?? "30") ?? 30))
        }
        // Pasted text must not enter the corpus.
        _ = try await client.command(.learning(.observe(text: "貼り付けた文章は学習しない", origin: .pasted)))
        try await Task.sleep(for: .seconds(Int(ProcessInfo.processInfo.environment["TENARAI_TEST_P13N_WAIT"] ?? "20") ?? 20))
        try await runPersonaSet(client, label: "afterLearning")
    }
}

// MARK: terminal-like context cost (2026-10-11)
extension Matrix {
    @MainActor
    static func runContextCost(_ client: MatrixClient) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        let shellLines = (0..<80).map { i in "drwxr-xr-x  \(i % 9) user staff  \(4096 + i) Oct 11 10:\(10 + i % 50) project\(i)\nuser@devhost:~/projects$ ls -la" }
        let terminalLeft = String(shellLines.joined(separator: "\n").suffix(4096)) + "\nuser@devhost:~$ echo "
        let terminalRight = String(repeating: " ", count: 80) + String(repeating: "\n" + String(repeating: " ", count: 80), count: 30)
        let chatLeft = "昨日の会議の件ですが、資料を確認しました。いくつか気になる点があったので、"
        let contexts: [(String, ConverterTextContext)] = [
            ("none", .init(leftSideContext: "", rightSideContext: "")),
            ("chat", .init(leftSideContext: chatLeft, rightSideContext: "")),
            ("terminal", .init(leftSideContext: terminalLeft, rightSideContext: terminalRight))
        ]
        for round in 0..<3 {
            for (label, context) in contexts {
                for raw in ["kyouhatenkigayoinodesanponiikimasu", "sa-ba-nosetteiwokakuninshitekudasai"] {
                    _ = try await client.command(.composition(.stopComposition))
                    var keyMs: [Double] = []
                    for c in raw {
                        let start = Date()
                        _ = try await client.key(.letter(c), context: context, live: true)
                        keyMs.append(Date().timeIntervalSince(start) * 1000)
                    }
                    let start = Date()
                    _ = try await client.key(.space, context: context, live: true)
                    let spaceMs = Date().timeIntervalSince(start) * 1000
                    _ = try await client.command(.composition(.stopComposition))
                    emit("CTXCOST", ["round": round, "context": label, "raw": raw, "key_ms": keyMs, "space_ms": spaceMs])
                }
            }
        }
    }
}

// MARK: learned conversions maintenance (2026-10-15)
extension Matrix {
    @MainActor
    static func runLearnedConversions(_ client: MatrixClient) async throws {
        let before = try await client.send(.maintenance(.listLearnedConversions)).learnedConversions ?? []
        let fragments = before.filter(\.hasPendingRomaji)
        let target = before.first { !$0.hasPendingRomaji && $0.word.count >= 2 }
        let toForget = Array(fragments.prefix(3)) + (target.map { [$0] } ?? [])
        let after = try await client.send(.maintenance(.forgetLearnedConversions(toForget))).learnedConversions ?? []
        let remaining = toForget.filter { item in after.contains { $0.word == item.word } }
        emit("LEARNED", ["before": before.count, "fragments": fragments.count, "forgot": toForget.count,
                         "after": after.count, "stillPresent": remaining.count])
    }
}

// MARK: apps excluded from learning (2026-10-15)
extension Matrix {
    /// A commit in an excluded app (default list: terminals) teaches nothing; the same
    /// commit in another app is learned. Checks conversion memory and tendencies.
    @MainActor
    static func runExcludedApp(serviceName: String) async throws {
        func session(app: String) async throws -> MatrixClient {
            let client = MatrixClient(serviceName: serviceName)
            try await client.open()
            client.pendingActivation = .init(
                config: .init(aiBackendPreference: .off, openAIModelName: "", openAIEndpoint: "",
                              openAIAPIKey: .init(""), includeContextInAITransform: false),
                inputLanguage: .japanese, clientIdentifier: app)
            return client
        }
        /// Commits the second candidate, which is never learned unless chosen.
        func commitSecond(_ client: MatrixClient, raw: String) async throws -> String? {
            _ = try await client.command(.composition(.stopComposition))
            for c in raw { _ = try await client.key(.letter(c), live: false) }
            _ = try await client.key(.space, live: false)
            let opened = try await client.key(.space, live: false)
            guard case .selecting(let candidates, let index) = opened.snapshot.candidateWindow,
                  let index, candidates.indices.contains(index) else { return nil }
            _ = try await client.key(.enter, live: false)
            return candidates[index].text
        }
        let terminal = try await session(app: "com.apple.Terminal")
        _ = try await terminal.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        _ = try await terminal.command(.learning(.deleteAll))
        let editor = try await session(app: "test.editor")
        let terminalWord = try await commitSecond(terminal, raw: "kousei")
        let editorWord = try await commitSecond(editor, raw: "kenshou")
        for text in ["サーバーの設定を変更しました", "ログを調査して原因を特定する"] {
            _ = try await terminal.command(.learning(.observe(text: text, origin: .typed)))
        }
        try await Task.sleep(for: .milliseconds(300))
        let terminalTendencies = try await terminal.command(.learning(.list)).localTendencies ?? []
        for text in ["サーバーの設定を変更しました", "ログを調査して原因を特定する"] {
            _ = try await editor.command(.learning(.observe(text: text, origin: .typed)))
        }
        var editorTendencies: [LocalTendency] = []
        for _ in 0..<40 {
            editorTendencies = try await editor.command(.learning(.list)).localTendencies ?? []
            if !editorTendencies.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let learned: [LearnedConversion] = try await editor.send(.maintenance(.listLearnedConversions)).learnedConversions ?? []
        let terminalLearned = learned.contains { $0.word == terminalWord && $0.reading == "コウセイ" }
        let editorLearned = learned.contains { $0.word == editorWord && $0.reading == "ケンショウ" }
        let result: [String: Any] = [
            "terminalWord": terminalWord ?? "", "editorWord": editorWord ?? "",
            "terminalLearned": terminalLearned, "editorLearned": editorLearned,
            "terminalTendencies": terminalTendencies.count, "editorTendencies": editorTendencies.count
        ]
        emit("EXCLUDED", result)
        _ = try await editor.command(.learning(.deleteAll))
    }
}

// MARK: measuring the personal model on the user's commits (2026-10-15)
extension Matrix {
    /// Commits the expected conversion of each accuracy case (as a user correcting
    /// candidates would), then adds enough text to rebuild the model; the rebuild first
    /// measures the old model on those commits. Reads the result back through settings.
    @MainActor
    static func runPersonalEvaluation(_ client: MatrixClient) async throws {
        _ = try await client.command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        _ = try await client.command(.settings(.update(key: Config.ZenzaiPersonalizationLevel.key, value: .string("auto"))))
        var committed = 0
        for item in accuracyCases {
            _ = try await client.command(.composition(.stopComposition))
            for c in item.raw { _ = try await client.key(.letter(c), live: false) }
            _ = try await client.key(.space, live: false)
            var response = try await client.key(.space, live: false)
            guard case .selecting(let candidates, let start) = response.snapshot.candidateWindow,
                  let target = candidates.firstIndex(where: { $0.text == item.expected }) else { continue }
            var index = start ?? 0
            while index < target {
                response = try await client.key(.down, live: false)
                index += 1
            }
            _ = try await client.key(.enter, live: false)
            committed += 1
        }
        let lines = accuracyCases.map { $0.left + $0.expected + $0.right + "。" }
        for line in lines.prefix(30) {
            _ = try await client.command(.learning(.observe(text: line, origin: .typed)))
            try await Task.sleep(for: .milliseconds(40))
        }
        var title = ""
        let started = Date()
        while Date().timeIntervalSince(started) < 240 {
            try await Task.sleep(for: .seconds(2))
            let settings = try await client.command(.settings(.list(capabilities: .init()))).settings
            title = settings.first { $0.key == Config.ZenzaiPersonalizationLevel.key }?.title ?? ""
            if title.contains("文節") { break }
        }
        emit("P13N_EVAL", ["committed": committed, "title": title, "seconds": Int(Date().timeIntervalSince(started))])
    }
}

// MARK: personal voice set (2026-11-11)
/// Sentences in a personal register (dialect, technical talk, spoken
/// forms written as said). Cases come from a JSON file so sets can grow without a
/// rebuild: [{"id", "group", "variant", "raw", "left", "right", "accept": [..], "app"}].
struct VoiceCase: Decodable {
    var id: String
    var group: String
    var variant: String
    var raw: String
    var left: String
    var right: String?
    var accept: [String]
    var app: String?
}

extension Matrix {
    @MainActor
    static func runVoiceSet(_ client: MatrixClient, path: String) async throws {
        let cases = try JSONDecoder().decode([VoiceCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        // Measurement never commits, so cases cannot teach each other.
        var currentApp: String?
        for item in cases {
            for live in [true, false] {
                _ = try await client.command(.composition(.stopComposition))
                if item.app != currentApp {
                    currentApp = item.app
                    client.pendingActivation = .init(
                        config: .init(aiBackendPreference: .off, openAIModelName: "", openAIEndpoint: "",
                                      openAIAPIKey: .init(""), includeContextInAITransform: false),
                        inputLanguage: .japanese, clientIdentifier: item.app)
                }
                let context = ConverterTextContext(leftSideContext: item.left, rightSideContext: item.right ?? "")
                var last: ConverterServerResponse?
                var keyMs: [Double] = []
                for c in item.raw {
                    let start = Date()
                    last = try await client.key(.letter(c), context: context, live: live)
                    keyMs.append(Date().timeIntervalSince(start) * 1000)
                }
                let liveText = last?.markedString ?? ""
                let start = Date()
                var opened = try await client.key(.space, context: context, live: live)
                if !live { opened = try await client.key(.space, context: context, live: live) }
                let spaceMs = Date().timeIntervalSince(start) * 1000
                var texts: [String] = []
                if case .selecting(let candidates, _) = opened.snapshot.candidateWindow { texts = candidates.map(\.text) }
                let rank = texts.firstIndex { item.accept.contains($0) }.map { $0 + 1 } ?? 0
                emit("VOICE", ["id": item.id, "group": item.group, "variant": item.variant, "raw": item.raw,
                               "accept": item.accept, "live": live, "liveText": liveText,
                               "spaceText": opened.markedString, "rank": rank, "top9": Array(texts.prefix(9)),
                               "key_ms": keyMs, "space_ms": spaceMs])
            }
        }
        _ = try await client.command(.composition(.stopComposition))
    }
}

// MARK: candidate window sprint (2026-11-19)
/// Scripted key sequences; every reply is printed so invariants about the candidate
/// window (which row is highlighted, when it is shown or hidden, what is inserted) are
/// checked outside, over many patterns: [{"id", "live", "left", "steps": ["text:you",
/// "space", "enter", "esc", "bs", "down", "up", "left", "right", "shiftLeft",
/// "shiftRight", "tab", "num:3", "num:3@9", "stop"]}].
struct SprintScenario: Decodable {
    var id: String
    var live: Bool
    var left: String?
    var steps: [String]
}

extension Matrix {
    @MainActor
    static func runCandidateSprint(_ client: MatrixClient, path: String) async throws {
        let scenarios = try JSONDecoder().decode([SprintScenario].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        func describe(_ response: ConverterServerResponse, step: String, ms: Double) -> [String: Any] {
            var row: [String: Any] = ["step": step, "ms": ms, "handled": response.handled,
                                      "state": String(describing: response.inputState.inputState),
                                      "inserted": response.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil },
                                      "marked": response.snapshot.markedText.elements.map { ["t": $0.content, "f": String(describing: $0.focus)] },
                                      "empty": response.snapshot.isEmpty]
            switch response.snapshot.candidateWindow {
            case .hidden: row["window"] = "hidden"
            case .composing(let candidates, let selection):
                row["window"] = "composing"; row["sel"] = selection ?? -1; row["count"] = candidates.count
                row["cands"] = candidates.prefix(12).map(\.text)
            case .selecting(let candidates, let selection):
                row["window"] = "selecting"; row["sel"] = selection ?? -1; row["count"] = candidates.count
                row["cands"] = candidates.prefix(12).map(\.text)
                if let selection, candidates.indices.contains(selection) { row["selText"] = candidates[selection].text }
                row["dups"] = candidates.count - Set(candidates.map(\.text)).count
            }
            return row
        }
        for scenario in scenarios {
            _ = try await client.command(.composition(.stopComposition))
            let context = ConverterTextContext(leftSideContext: scenario.left ?? "", rightSideContext: "")
            var rows: [[String: Any]] = []
            var failure: String?
            for step in scenario.steps {
                do {
                    if step == "stop" {
                        _ = try await client.command(.composition(.stopComposition))
                        continue
                    }
                    var keys: [(MatrixKey, Int)] = []
                    if step.hasPrefix("text:") {
                        keys = step.dropFirst(5).map { (.letter($0), 0) }
                    } else if step.hasPrefix("num:") {
                        let parts = step.dropFirst(4).split(separator: "@")
                        keys = [(.number(Int(parts[0]) ?? 1), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)]
                    } else {
                        let named: [String: MatrixKey] = ["space": .space, "enter": .enter, "esc": .escape, "bs": .backspace,
                                                          "down": .down, "up": .up, "left": .left, "right": .right,
                                                          "shiftLeft": .shiftLeft, "shiftRight": .shiftRight,
                                                          "tab": .init(characters: "\t", code: 48)]
                        guard let key = named[step] else { failure = "unknown step \(step)"; break }
                        keys = [(key, 0)]
                    }
                    var inserted: [String] = []
                    var slowest = 0.0
                    for (index, (key, start)) in keys.enumerated() {
                        let started = Date()
                        let response = try await client.key(key, context: context, live: scenario.live, visibleCandidateStartIndex: start)
                        slowest = max(slowest, Date().timeIntervalSince(started) * 1000)
                        inserted += response.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }
                        // For typed text only the reply to the last key is a checkpoint.
                        if index == keys.count - 1 {
                            var row = describe(response, step: step, ms: slowest)
                            row["inserted"] = inserted
                            rows.append(row)
                        }
                    }
                } catch {
                    failure = "\(error)"
                    break
                }
            }
            emit("SPRINT", ["id": scenario.id, "live": scenario.live, "rows": rows, "error": failure ?? NSNull()])
        }
        _ = try await client.command(.composition(.stopComposition))
    }
}
