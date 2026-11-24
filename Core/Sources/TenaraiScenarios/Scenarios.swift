import Foundation
import Core

@objc protocol ScenarioXPC {
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
}

@main struct Scenarios {
    @MainActor static func main() async throws {
        // A bounded watchdog prevents a hung helper from masquerading as success.
        let matrixModes = ["--segment-matrix", "--accuracy-matrix", "--perf-matrix", "--soak", "--fault-matrix", "--context-sets", "--style-set", "--tone-learning", "--persona-set", "--p13n-e2e", "--context-cost", "--learned", "--excluded-app", "--p13n-eval", "--voice-set", "--candidate-sprint"]
        let matrixMode = CommandLine.arguments.first { matrixModes.contains($0) }
        let watchdog = matrixMode == "--soak" ? 7200 : (matrixMode != nil || CommandLine.arguments.contains("--context-sprint") ? 1800 : 90)
        Task.detached { try? await Task.sleep(for: .seconds(watchdog)); exit(2) }
        if let matrixMode {
            let client = MatrixClient(serviceName: "local.tenarai.inputmethod.tenarai.Scenario")
            defer { client.invalidate() }
            try await client.open()
            if let raw = ProcessInfo.processInfo.environment["TENARAI_BENCH_LIMIT"], let limit = Int(raw) {
                _ = try await client.command(.settings(.update(key: Config.ZenzaiInferenceLimit.key, value: .int(limit))))
            }
            switch matrixMode {
            case "--segment-matrix": try await Matrix.runSegments(client)
            case "--accuracy-matrix":
                try await Matrix.runAccuracy(client, learningLabel: ProcessInfo.processInfo.environment["TENARAI_LEARNING_LABEL"] ?? "none")
            case "--perf-matrix": try await Matrix.runPerformance(client)
            case "--context-sets": try await Matrix.runContextSets(client, label: ProcessInfo.processInfo.environment["TENARAI_LEARNING_LABEL"] ?? "")
            case "--style-set": try await Matrix.runStyleSet(client, label: ProcessInfo.processInfo.environment["TENARAI_LEARNING_LABEL"] ?? "")
            case "--tone-learning": try await Matrix.runToneLearning(serviceName: "local.tenarai.inputmethod.tenarai.Scenario")
            case "--persona-set": try await Matrix.runPersonaSet(client, label: ProcessInfo.processInfo.environment["TENARAI_LEARNING_LABEL"] ?? "")
            case "--p13n-e2e":
                let corpusPath = ProcessInfo.processInfo.environment["TENARAI_P13N_CORPUS"] ?? ""
                let lines = ((try? String(contentsOfFile: corpusPath, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
                try await Matrix.runPersonalModelEndToEnd(client, corpus: lines)
            case "--context-cost": try await Matrix.runContextCost(client)
            case "--learned": try await Matrix.runLearnedConversions(client)
            case "--p13n-eval": try await Matrix.runPersonalEvaluation(client)
            case "--candidate-sprint": try await Matrix.runCandidateSprint(client, path: ProcessInfo.processInfo.environment["TENARAI_SPRINT_SCRIPT"] ?? "")
            case "--voice-set": try await Matrix.runVoiceSet(client, path: ProcessInfo.processInfo.environment["TENARAI_VOICE_CASES"] ?? "")
            case "--excluded-app": try await Matrix.runExcludedApp(serviceName: "local.tenarai.inputmethod.tenarai.Scenario")
            case "--soak": try await Matrix.runSoak(client, keys: Int(ProcessInfo.processInfo.environment["TENARAI_SOAK_KEYS"] ?? "9000") ?? 9000)
            default:
                try await Matrix.runFaultMatrix(serviceName: "local.tenarai.inputmethod.tenarai.Scenario", label: "local.tenarai.inputmethod.tenarai.Scenario")
            }
            return
        }
        let connection = NSXPCConnection(machServiceName: "local.tenarai.inputmethod.tenarai.Scenario")
        connection.remoteObjectInterface = NSXPCInterface(with: ScenarioXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        func send(_ command: ConverterServerCommand) async throws -> ConverterServerResponse {
            let data = try ConverterServerCodec.encode(command)
            return try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    continuation.resume(throwing: error)
                } as! ScenarioXPC
                proxy.handleCommand(data) { result, error in
                    do {
                        guard let result else { throw NSError(domain: "Scenario", code: 1, userInfo: [NSLocalizedDescriptionKey: error as String? ?? "missing response"]) }
                        continuation.resume(returning: try ConverterServerCodec.decodeResponse(from: result))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let session = UUID().uuidString
        _ = try await send(.openSession(sessionID: session, command: .lifecycle(.activate)))
        func command(_ value: ConverterSessionCommand) async throws -> ConverterServerResponse {
            try await send(.session(sessionID: session, command: value))
        }
        var eventID: UInt64 = 0
        func key(_ text: String, code: UInt16 = 0, context: ConverterTextContext = .init(), shifted: Bool = false, live: Bool = true) async throws -> ConverterServerResponse {
            eventID += 1
            return try await command(.handleKeyEvent(.init(eventID: eventID,
                event: .init(modifierFlags: shifted ? [.shift] : [], characters: text, charactersIgnoringModifiers: text.lowercased(), keyCode: code),
                inputStyle: .defaultRomanToKana, liveConversionEnabled: live, enableDebugWindow: false,
                enableSuggestion: false, context: context)))
        }
        if let raw = ProcessInfo.processInfo.environment["TENARAI_BENCH_LIMIT"], let limit = Int(raw) {
            _ = try await command(.settings(.update(key: Config.ZenzaiInferenceLimit.key, value: .int(limit))))
        }
        if CommandLine.arguments.contains("--context-sprint") {
            _ = try await command(.settings(.update(key: Config.Learning.key, value: .string("nothing"))))
            for (caseID, item) in contextSprintCases.prefix(Int(ProcessInfo.processInfo.environment["TENARAI_SPRINT_CASES"] ?? String(contextSprintCases.count)) ?? contextSprintCases.count).enumerated() {
                for live in [true, false] {
                    for mode in ["none", "left", "right", "both", "unrelated"] {
                        _ = try await command(.composition(.stopComposition))
                        let context = ConverterTextContext(
                            leftSideContext: mode == "unrelated" ? "今日は公園で花を見ました。" : (["left", "both"].contains(mode) ? item.left : ""),
                            rightSideContext: ["right", "both"].contains(mode) ? item.right : "")
                        var latency: [Double] = []
                        var earlyCommits = 0
                        var last: ConverterServerResponse?
                        for character in item.raw {
                            let start = Date()
                            last = try await key(String(character), context: context, live: live)
                            latency.append(Date().timeIntervalSince(start) * 1000)
                            earlyCommits += last!.effects.filter { if case .insertText = $0 { return true }; return false }.count
                        }
                        let liveText = last!.snapshot.markedText.elements.map(\.content).joined()
                        let start = Date()
                        var opened = try await key(" ", code: 49, context: context, live: live)
                        if !live { opened = try await key(" ", code: 49, context: context, live: live) }
                        let spaceMs = Date().timeIntervalSince(start) * 1000
                        guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow else { fatalError("No sprint candidates") }
                        let texts = candidates.map(\.text)
                        let rank = texts.firstIndex(of: item.expected).map { $0 + 1 } ?? 0
                        let chosen = rank > 0 ? rank - 1 : 0
                        _ = try await command(.candidate(.selectCandidate(index: chosen)))
                        let committed = try await key("\r", code: 36, context: context, live: live)
                        let output = committed.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }.joined()
                        let commitOK = output == texts[chosen]
                        _ = try await key("n", live: live)
                        let next = try await key("i", live: live)
                        let continueOK = next.snapshot.markedText.elements.map(\.content).joined() == "に"
                        let row: [String: Any] = ["id": caseID, "group": item.group, "raw": item.raw,
                            "expected": item.expected, "mode": mode, "live": live, "rank": rank,
                            "top9": Array(texts.prefix(9)), "liveText": liveText, "key_ms": latency,
                            "space_ms": spaceMs, "earlyCommits": earlyCommits, "commitOK": commitOK, "continueOK": continueOK]
                        print("CONTEXT_SPRINT " + String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                        fflush(nil)
                    }
                }
            }
            return
        }
        if CommandLine.arguments.contains("--performance") {
            var times: [Double] = []
            var outputs: [String] = []
            for _ in 0..<3 {
                for input in ["sa-ba-wokanrisuru", "kyouhatenkigayoinodesanponiikimasu", "konokinounoseinouwokakuninsimasu", "tottokimasuyo"] {
                    _ = try await command(.composition(.stopComposition))
                    for character in input {
                        let start = Date()
                        _ = try await key(String(character), context: .init(leftSideContext: "", rightSideContext: ""))
                        times.append(Date().timeIntervalSince(start) * 1000)
                    }
                    let result = try await key("\r", code: 36)
                    outputs.append(result.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }.joined())
                }
            }
            times.sort()
            let report: [String: Any] = ["keys": times.count, "p50_ms": times[times.count/2], "p95_ms": times[Int(Double(times.count)*0.95)], "max_ms": times.last!, "outputs": outputs]
            print("PERFORMANCE " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
            return
        }
        var timings: [Double] = []
        if CommandLine.arguments.contains("--fault-store") {
            _ = try await command(.learning(.observe(text: "サーバー", origin: .typed)))
            var reportedFailure = false
            do { _ = try await command(.learning(.list)) } catch { reportedFailure = true }
            precondition(reportedFailure, "unwritable learning store appeared successful")
            for character in "sa-ba-" { _ = try await key(String(character)) }
            let result = try await command(.composition(.commit))
            precondition(result.effects.contains { if case .insertText(let text) = $0 { return !text.isEmpty }; return false })
            print("fault injection: learning storage unavailable; error reported and conversion/commit continued PASS")
            return
        }
        for (input, left, right) in [("sa-ba-", "Dockerの", "を再起動する"), ("gyouretu", "固有値と", "を計算する"), ("konnichiha", "", ""), ("tottokimasuyo", "", ""), ("tottokimasuyo", "ちゃんと動画も", ""), ("totteokimasuyo", "ちゃんと動画も", "")] {
            _ = try await command(.composition(.stopComposition))
            let context = ConverterTextContext(leftSideContext: left, rightSideContext: right)
            var response: ConverterServerResponse?
            for character in input {
                let start = Date()
                response = try await key(String(character), context: context)
                timings.append(Date().timeIntervalSince(start) * 1000)
                precondition(response!.effects.allSatisfy { if case .insertText = $0 { return false }; return true }, "live input unexpectedly committed text")
            }
            precondition(response?.snapshot.isEmpty == false)
            let committed = try await command(.composition(.commit))
            let strings = committed.effects.compactMap { effect -> String? in if case .insertText(let text) = effect { return text }; return nil }
            precondition(!strings.joined().isEmpty)
            print("engine+XPC input=\(input) output=\(strings.joined()) context=\(!left.isEmpty)")
            fflush(nil)
        }
        for reading in ["hashi", "hashini", "hashiniyoseru"] {
            _ = try await command(.composition(.stopComposition))
            for character in reading { _ = try await key(String(character)) }
            let selected = try await key(" ", code: 49)
            guard case .selecting(let candidates, _) = selected.snapshot.candidateWindow else { fatalError("No candidate list") }
            print("dictionary coverage \(reading): \(candidates.map(\.text))")
            precondition(candidates.contains { $0.text.hasPrefix("端") }, "Missing edge candidate")
        }
        _ = try await command(.composition(.stopComposition))
        // User-reported Shift+M, then unshifted a/c must stay Latin.
        for (letters, shiftedAll) in [("Mac", false), ("MAC", true)] {
            _ = try await command(.composition(.stopComposition))
            for (index, character) in letters.enumerated() {
                _ = try await key(String(character), shifted: index == 0 || shiftedAll)
            }
            let committed = try await key("\r", code: 36)
            let text = committed.effects.compactMap { effect -> String? in
                if case .insertText(let value) = effect { return value }; return nil
            }.joined()
            precondition(text == letters, "Shift Latin input: expected \(letters), got \(text)")
            for character in "sa-ba-" { _ = try await key(String(character)) }
            let japanese = try await key("\r", code: 36)
            precondition(japanese.effects.contains { if case .insertText("サーバー") = $0 { return true }; return false }, "Latin mode leaked past commit")
        }
        for (word, live) in [("Iphone", true), ("Mac", false), ("Docker", true)] {
            _ = try await command(.composition(.stopComposition))
            var literal = ""
            for (index, character) in word.enumerated() {
                literal.append(character)
                let response = try await key(String(character), shifted: index == 0, live: live)
                precondition(response.snapshot.markedText.elements.map(\.content).joined() == literal, "Latin input was transformed before Space")
                guard case .hidden = response.snapshot.candidateWindow else { fatalError("Latin candidates opened before Space") }
            }
            let opened = try await key(" ", code: 49, live: live)
            guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow, !candidates.isEmpty else { fatalError("Space did not open Latin candidates") }
            print("Shift+Space \(word): \(candidates.map(\.text))")
            precondition(candidates.contains { $0.text == word }, "Original Latin spelling is missing")
            let expectedReading = ["Iphone": "アイフォン", "Mac": "マック", "Docker": "ドッカー"][word]!
            precondition(candidates.contains { $0.text == expectedReading }, "Missing katakana reading")
            if word == "Iphone" { precondition(candidates.contains { $0.text == "iPhone" }, "Missing iPhone spelling candidate") }
            let choice = candidates.firstIndex { $0.text == "iPhone" } ?? candidates.firstIndex { $0.text == expectedReading }!
            _ = try await command(.candidate(.selectCandidate(index: choice)))
            let committed = try await key("\r", code: 36)
            precondition(committed.effects.contains { if case .insertText(candidates[choice].text) = $0 { return true }; return false })
        }
        // Regression: typing while a Shift-started candidate is selected commits it
        // and starts a fresh Japanese composition, without requiring Enter first.
        for live in [false, true] {
            for selectedText in ["iPhone", "アイフォン"] {
                for continuation in ["ni", "Mac"] {
                    _ = try await command(.composition(.stopComposition))
                    for (index, character) in "Iphone".enumerated() {
                        _ = try await key(String(character), shifted: index == 0, live: live)
                    }
                    let opened = try await key(" ", code: 49, live: live)
                    guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow,
                          let choice = candidates.firstIndex(where: { $0.text == selectedText }) else { fatalError("Missing continuation candidate") }
                    _ = try await command(.candidate(.selectCandidate(index: choice)))
                    var last: ConverterServerResponse?
                    for (index, character) in continuation.enumerated() {
                        let response = try await key(String(character), shifted: index == 0 && continuation == "Mac", live: live)
                        if index == 0 {
                            precondition(response.effects.contains { if case .insertText(selectedText) = $0 { return true }; return false }, "Selected spelling not committed before continuing")
                        } else {
                            precondition(!response.effects.contains { if case .insertText(selectedText) = $0 { return true }; return false }, "Selected spelling committed twice")
                        }
                        last = response
                    }
                    let marked = last!.snapshot.markedText.elements.map(\.content).joined()
                    precondition(marked == (continuation == "ni" ? "に" : "Mac"), "Latin continuation leaked: \(marked)")
                    let committed = try await key("\r", code: 36, live: live)
                    precondition(committed.effects.contains { if case .insertText(continuation == "ni" ? "に" : "Mac") = $0 { return true }; return false })
                }
            }
        }
        print("Shift candidate -> Japanese/restarted Latin continuation: 8 scenarios PASS")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyy/MM/dd"
        for live in [false, true] {
            for (raw, fixed, offset) in [("1230", "12:30", 0), ("930", "09:30", 0), ("kyou", "", 0), ("ashita", "", 1)] {
                _ = try await command(.composition(.stopComposition))
                for character in raw { _ = try await key(String(character), live: live) }
                let expected = fixed.isEmpty ? dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!) : fixed
                var opened = try await key(" ", code: 49, live: live)
                if !live { opened = try await key(" ", code: 49, live: live) }
                guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow,
                      let index = candidates.firstIndex(where: { $0.text == expected }) else { fatalError("Date/time candidate missing: \(raw)") }
                precondition(index <= 1, "Date/time candidate is hidden below the first page: \(raw) index=\(index)")
                _ = try await command(.candidate(.selectCandidate(index: index)))
                let committed = try await key("\r", code: 36, live: live)
                precondition(committed.effects.contains { if case .insertText(expected) = $0 { return true }; return false })
                _ = try await key("n", live: live)
                let next = try await key("i", live: live)
                precondition(next.snapshot.markedText.elements.map(\.content).joined() == "に")
            }
        }
        print("Date/time Space conversion, commit, continuation with live on/off: 8 scenarios PASS")

        for (raw, expected) in [("ohayougzaimasu", "おはようございます"), ("ohayougozaiamsu", "おはようございます"), ("arigatougozzaimasu", "ありがとうございます")] {
            _ = try await command(.composition(.stopComposition))
            for character in raw { _ = try await key(String(character)) }
            let opened = try await key(" ", code: 49)
            guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow,
                  let index = candidates.firstIndex(where: { $0.text == expected }) else { fatalError("Japanese typo correction missing: \(raw)") }
            _ = try await command(.candidate(.selectCandidate(index: index)))
            let committed = try await key("\r", code: 36)
            precondition(committed.effects.contains { if case .insertText(expected) = $0 { return true }; return false })
            _ = try await key("n")
            let next = try await key("i")
            precondition(next.snapshot.markedText.elements.map(\.content).joined() == "に", "Typo commit left residual input")
        }
        print("Japanese missing/repeated/transposed key correction and continuation: 3 scenarios PASS")

        for (typo, correction, reading) in [("Iphnoe", "iPhone", "アイフォン"), ("Dokcer", "Docker", "ドッカー")] {
            _ = try await command(.composition(.stopComposition))
            var literal = ""
            for (index, character) in typo.enumerated() {
                literal.append(character)
                let response = try await key(String(character), shifted: index == 0)
                precondition(response.snapshot.markedText.elements.map(\.content).joined() == literal)
                guard case .hidden = response.snapshot.candidateWindow else { fatalError("Typo candidates opened before Space") }
            }
            let opened = try await key(" ", code: 49)
            guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow else { fatalError("Typo candidate list missing") }
            precondition(candidates.first?.text == typo, "Typo replaced before user selection")
            precondition(candidates.contains { $0.text == correction }, "Missing close typo correction")
            precondition(candidates.contains { $0.text == reading }, "Missing corrected katakana reading")
            print("Shift+Space typo \(typo): \(candidates.map(\.text))")
            let selected = candidates.firstIndex { $0.text == correction }!
            _ = try await command(.candidate(.selectCandidate(index: selected)))
            let committed = try await key("\r", code: 36)
            precondition(committed.effects.contains { if case .insertText(correction) = $0 { return true }; return false })
        }
        // Sprint matrix: real XPC key sequences, live setting ON/OFF, commit and cancel/edit.
        var latinMatrixCount = 0
        var latinMatrixTimings: [Double] = []
        for live in [true, false] {
            for (index, word) in ["Iphnoe", "Dokcer", "Servre", "Macbok", "Keybaord", "Comptuer", "Netwrok", "Databsae", "Pyhton", "Swfit", "Widnows", "Browsre", "Packgae", "Porject", "Messgae", "Discord", "ChatGPT", "Vikunja", "Forgejo", "MAC"].enumerated() {
                _ = try await command(.composition(.stopComposition))
                var literal = ""
                for (offset, character) in word.enumerated() {
                    literal.append(character)
                    let start = Date()
                    let response = try await key(String(character), shifted: offset == 0, live: live)
                    latinMatrixTimings.append(Date().timeIntervalSince(start) * 1000)
                    precondition(response.snapshot.markedText.elements.map(\.content).joined() == literal, "Matrix typing changed \(word)")
                    precondition(response.effects.allSatisfy { if case .insertText = $0 { return false }; return true })
                    guard case .hidden = response.snapshot.candidateWindow else { fatalError("Matrix candidates opened before Space") }
                }
                let opened = try await key(" ", code: 49, live: live)
                guard case .selecting(let candidates, _) = opened.snapshot.candidateWindow else { fatalError("Matrix Space failed") }
                guard let original = candidates.firstIndex(where: { $0.text == word }) else { fatalError("Matrix original missing") }
                if index.isMultiple(of: 2) {
                    _ = try await command(.candidate(.selectCandidate(index: original)))
                } else {
                    let escaped = try await key("\u{1b}", code: 53, live: live)
                    precondition(escaped.snapshot.markedText.elements.map(\.content).joined() == word)
                    guard case .hidden = escaped.snapshot.candidateWindow else { fatalError("Matrix Escape failed") }
                    _ = try await key("\u{7f}", code: 51, live: live)
                    let edited = try await key(String(word.last!), live: live)
                    precondition(edited.snapshot.markedText.elements.map(\.content).joined() == word)
                }
                let committed = try await key("\r", code: 36, live: live)
                precondition(committed.effects.contains { if case .insertText(word) = $0 { return true }; return false }, "Matrix commit changed original")
                latinMatrixCount += 1
            }
        }
        latinMatrixTimings.sort()
        print("LATIN_XPC_MATRIX \(latinMatrixCount) scenarios PASS; typing_key_ms p50=\(latinMatrixTimings[latinMatrixTimings.count/2]) p95=\(latinMatrixTimings[Int(Double(latinMatrixTimings.count)*0.95)]) max=\(latinMatrixTimings.last!)")
        // Explicit name choice persists through the local tendency store and can be deleted.
        _ = try await command(.composition(.stopComposition))
        _ = try await command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        for (index, character) in "Vikunja".enumerated() { _ = try await key(String(character), shifted: index == 0) }
        let nameWindow = try await key(" ", code: 49)
        guard case .selecting(let names, _) = nameWindow.snapshot.candidateWindow,
              let nameIndex = names.firstIndex(where: { $0.text == "Vikunja" }) else { fatalError("Missing personal name original") }
        _ = try await command(.candidate(.selectCandidate(index: nameIndex)))
        _ = try await key("\r", code: 36)
        var selectedNameStored = false
        for _ in 0..<30 {
            let values = try await command(.learning(.list)).localTendencies ?? []
            if values.contains(where: { $0.key == "selectedLatin:vikunja" && $0.value == "Vikunja" }) { selectedNameStored = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(selectedNameStored, "Explicit name choice was not persisted")
        for (index, character) in "Vikunaj".enumerated() { _ = try await key(String(character), shifted: index == 0) }
        let learnedWindow = try await key(" ", code: 49)
        guard case .selecting(let learnedNames, _) = learnedWindow.snapshot.candidateWindow else { fatalError("Missing learned list") }
        precondition(learnedNames.contains { $0.text == "Vikunja" }, "Learned name not used for typo correction")
        _ = try await command(.composition(.stopComposition))
        _ = try await command(.learning(.delete(key: "selectedLatin:vikunja")))
        for (index, character) in "Vikunaj".enumerated() { _ = try await key(String(character), shifted: index == 0) }
        let removedWindow = try await key(" ", code: 49)
        guard case .selecting(let removedNames, _) = removedWindow.snapshot.candidateWindow else { fatalError("Missing list after delete") }
        precondition(!removedNames.contains { $0.text == "Vikunja" }, "Deleted name still used")
        _ = try await command(.composition(.stopComposition))
        _ = try await command(.learning(.delete(key: "selectedLatin:forgejo")))
        _ = try await command(.settings(.update(key: Config.Learning.key, value: .string("onlyOutput"))))
        for (index, character) in "Forgejo".enumerated() { _ = try await key(String(character), shifted: index == 0) }
        let pausedWindow = try await key(" ", code: 49)
        guard case .selecting(let pausedNames, _) = pausedWindow.snapshot.candidateWindow,
              let pausedIndex = pausedNames.firstIndex(where: { $0.text == "Forgejo" }) else { fatalError("Missing paused original") }
        _ = try await command(.candidate(.selectCandidate(index: pausedIndex)))
        _ = try await key("\r", code: 36)
        let pausedValues = try await command(.learning(.list)).localTendencies ?? []
        precondition(!pausedValues.contains { $0.key == "selectedLatin:forgejo" }, "Learning pause ignored")
        _ = try await command(.settings(.update(key: Config.Learning.key, value: .string("inputAndOutput"))))
        print("Personal names: explicit choice/store/typo/delete/pause PASS")
        _ = try await key("I", shifted: true)
        for character in "phone" { _ = try await key(String(character)) }
        _ = try await key(" ", code: 49)
        let escaped = try await key("\u{1b}", code: 53)
        precondition(escaped.snapshot.markedText.elements.map(\.content).joined() == "Iphone")
        guard case .hidden = escaped.snapshot.candidateWindow else { fatalError("Escape did not hide Latin candidates") }
        _ = try await key("\u{7f}", code: 51)
        _ = try await key("e")
        let reopened = try await key(" ", code: 49)
        guard case .selecting(let reopenedCandidates, _) = reopened.snapshot.candidateWindow else { fatalError("Could not reopen Latin candidates after edit") }
        precondition(reopenedCandidates.contains { $0.text == "iPhone" })
        _ = try await command(.composition(.stopComposition))
        _ = try await key("M", shifted: true)
        _ = try await key("a")
        _ = try await key("\u{7f}", code: 51)
        _ = try await key("c")
        let edited = try await key("\r", code: 36)
        precondition(edited.effects.contains { if case .insertText("Mc") = $0 { return true }; return false })
        _ = try await key("M", shifted: true)
        _ = try await key("\u{7f}", code: 51)
        _ = try await key("a")
        let reset = try await key("\r", code: 36)
        precondition(reset.effects.contains { if case .insertText("あ") = $0 { return true }; return false }, "Deleting all Latin text did not reset mode")
        _ = try await key("M", shifted: true)
        _ = try await command(.composition(.stopComposition))
        _ = try await key("a")
        let cancelled = try await key("\r", code: 36)
        precondition(cancelled.effects.contains { if case .insertText("あ") = $0 { return true }; return false }, "Cancel did not reset mode")
        print("Shift Latin: Mac/MAC, edit, delete-all, cancel, return to Japanese PASS")
        // User-reported: "Ab1" lost the first digit. Digits need their real key codes;
        // key() defaults to keyCode 0, which never becomes UserAction.number.
        let digitKeyCodes: [Character: UInt16] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29]
        for live in [true, false] {
            for typed in ["Ab1", "Ab 1", "Ab 12", "Ab 0", "ABcd123!x"] {
                _ = try await command(.composition(.stopComposition))
                var output = ""
                var trail: [String] = []
                for character in typed {
                    let code = character == " " ? 49 : (character == "!" ? 18 : (digitKeyCodes[character] ?? 0))
                    let response = try await key(String(character), code: code, shifted: character.isUppercase || character == "!", live: live)
                    let inserted = response.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }.joined()
                    output += inserted
                    trail.append("\(character)->[\(inserted)|\(response.snapshot.markedText.elements.map(\.content).joined())|\(response.inputState)]")
                }
                let committed = try await key("\r", code: 36, live: live)
                output += committed.effects.compactMap { if case .insertText(let text) = $0 { return text }; return nil }.joined()
                precondition(output == typed, "Shift Latin digits (live=\(live)): typed \(typed), got \(output) \(trail)")
            }
        }
        print("Shift Latin followed by digit/symbol key codes, with and without Space: 10 scenarios PASS")
        // User-reported: while Space cycles candidates, the highlighted row and the
        // converted text in the field disagree.
        var highlightReport: [String] = []
        for live in [true, false] {
            for reading in ["kisha", "kyouhatenkigaii", "watasihanihonjindesu"] {
                _ = try await command(.composition(.stopComposition))
                for character in reading { _ = try await key(String(character), live: live) }
                for press in 1...8 {
                    let response = try await key(" ", code: 49, live: live)
                    // With live conversion off, the first Space only previews the top candidate.
                    if !live && press == 1 { continue }
                    guard case .selecting(let candidates, let selection) = response.snapshot.candidateWindow else {
                        highlightReport.append("\(reading) live=\(live) space\(press): \(response.snapshot.candidateWindow)")
                        continue
                    }
                    let focused = response.snapshot.markedText.elements.filter { $0.focus == .focused }.map(\.content).joined()
                    let highlighted = selection.flatMap { candidates.indices.contains($0) ? candidates[$0].text : nil }
                    if highlighted != focused {
                        highlightReport.append("\(reading) live=\(live) space\(press): row=\(selection.map(String.init) ?? "nil") '\(highlighted ?? "-")' field='\(focused)' marked=\(response.snapshot.markedText.elements.map { "\($0.content)/\($0.focus)" })")
                    }
                }
            }
        }
        precondition(highlightReport.isEmpty, "Candidate highlight differs from the converted text:\n" + highlightReport.joined(separator: "\n"))
        print("Space cycling: highlighted candidate equals the converted text in the field, live on/off: 6 scenarios PASS")
        _ = try await command(.learning(.deleteAll))
        _ = try await command(.learning(.observe(text: "サーバーとAPI", origin: .typed)))
        _ = try await command(.learning(.observe(text: "サーバーとDocker", origin: .typed)))
        var values: [LocalTendency] = []
        for _ in 0..<100 {
            values = try await command(.learning(.list)).localTendencies ?? []
            if values.contains(where: { $0.key == "spelling:server" && $0.evidence >= 2 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(values.contains { $0.key == "spelling:server" && $0.evidence >= 2 })
        _ = try await command(.composition(.stopComposition))
        for character in "tottokimasuyo" {
            _ = try await key(String(character), context: .init(leftSideContext: "ちゃんと動画も"))
        }
        let contextWins = try await command(.composition(.commit))
        if CommandLine.arguments.contains("--dictionary-only") {
            precondition(contextWins.effects.contains { if case .insertText(let text) = $0 { return !text.isEmpty }; return false })
            print("SKIP: model-based video-context ranking is disabled by security policy; dictionary commit PASS")
        } else {
        precondition(contextWins.effects.contains { if case .insertText("撮っときますよ") = $0 { return true }; return false }, "Technical learning overrode video context")
        print("Current video context retained after technical-domain learning PASS")
        }
        for character in "sa-ba-" { _ = try await key(String(character)) }
        _ = try await key(" ", code: 49)
        let before = try await command(.candidate(.selectCandidate(index: 0)))
        guard case .selecting(let candidates, _) = before.snapshot.candidateWindow, !candidates.isEmpty else {
            fatalError("selection scenario did not produce candidates")
        }
        _ = try await command(.learning(.edit(key: "spelling:server", value: "サーバ")))
        let after = try await command(.composition(.snapshot))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeCandidates = try encoder.encode(before.snapshot.candidateWindow)
        let afterCandidates = try encoder.encode(after.snapshot.candidateWindow)
        precondition(beforeCandidates == afterCandidates, "learning reordered selecting candidates")
        _ = try await command(.learning(.observe(text: "サーバー", origin: .typed)))
        let deleted = try await command(.learning(.deleteAll))
        precondition(deleted.localTendencies?.isEmpty == true)
        try await Task.sleep(for: .milliseconds(200))
        let final = try await command(.learning(.list))
        precondition(final.localTendencies?.isEmpty == true, "late learning revived deleted data")
        let other = try await send(.openSession(sessionID: UUID().uuidString, command: .composition(.snapshot)))
        precondition(other.snapshot.isEmpty, "composition leaked into a different text session")
        _ = try await command(.lifecycle(.synchronizeInputLanguage(.english)))
        timings.sort()
        print("learning/edit/delete/selection/session-isolation XPC PASS; key_ms p50=\(timings[timings.count/2]) p95=\(timings[Int(Double(timings.count-1)*0.95)]) max=\(timings.last!)")
        print("These are synthetic engine/XPC scenarios, not real-app or UI acceptance tests.")
    }
}
