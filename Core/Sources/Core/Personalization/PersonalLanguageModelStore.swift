import Crypto
import EfficientNGram
import Foundation

/// Personal n-gram language model for Zenzai's personalization.
///
/// Design decision (2026-10-05): keep the committed text itself locally so the model can
/// be rebuilt and deleted cleanly. Only text the user typed and committed is kept (never
/// pasted text), only on this Mac (excluded from backups, owner-only permissions), and
/// "reset learning data" deletes everything here.
///
/// Layout under `directory`:
/// - `corpus.txt`: one committed text per line
/// - `models/<generation>/lm_*.marisa`: each rebuild is a new directory, because the
///   converter caches models by path and would not reload a file replaced in place
/// Seeding from the converter's learned words was tried and rejected: those are
/// isolated words, and a model built from them lowered general accuracy (Oct 5).
public final class PersonalLanguageModelStore: @unchecked Sendable {
    public static let shared = PersonalLanguageModelStore(
        directory: AppGroup.applicationSupportDirectoryURL().appendingPathComponent("p13n", isDirectory: true)
    )

    /// n-gram order used by Zenzai's personalization.
    public static let order = 5
    /// Lines kept for training; older lines are dropped when the corpus grows beyond it.
    public static let maximumLines = 200_000
    public static let maximumLineLength = 1_000

    public let directory: URL
    private let lock = NSLock()
    private var cachedModelPrefix: String??
    private var linesSinceTraining = 0

    public init(directory: URL) {
        self.directory = directory
    }

    var corpusURL: URL { directory.appendingPathComponent("corpus.txt") }
    var modelsURL: URL { directory.appendingPathComponent("models", isDirectory: true) }

    /// A model from fewer lines than this would over-weight a few sentences.
    public static let minimumLinesForModel = 100

    // MARK: corpus

    /// Appends committed text. Returns the number of lines added.
    @discardableResult
    public func append(_ text: String) -> Int {
        let lines = Self.lines(from: text)
        guard !lines.isEmpty else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            if !FileManager.default.fileExists(atPath: corpusURL.path) {
                FileManager.default.createFile(atPath: corpusURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: corpusURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            linesSinceTraining += lines.count
            return lines.count
        } catch {
            return 0
        }
    }

    static func lines(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0.trimmingCharacters(in: .whitespaces).prefix(maximumLineLength)) }
            .filter { !$0.isEmpty }
    }

    /// Text was added after the newest model was built (e.g. before a restart).
    public var corpusIsNewerThanModel: Bool {
        guard let corpus = try? FileManager.default.attributesOfItem(atPath: corpusURL.path)[.modificationDate] as? Date else { return false }
        guard let prefix = currentModelPrefix(),
              let model = try? FileManager.default.attributesOfItem(atPath: prefix + "_c_abc.marisa")[.modificationDate] as? Date else { return true }
        return corpus > model
    }

    public var pendingLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return linesSinceTraining
    }

    // MARK: model

    /// `.../models/<generation>/lm`, or nil when no complete model exists.
    public func currentModelPrefix() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedModelPrefix { return cachedModelPrefix }
        let prefix = newestCompleteModel()
        cachedModelPrefix = .some(prefix)
        return prefix
    }

    private func newestCompleteModel() -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsURL.path) else { return nil }
        for name in names.sorted(by: >) where !name.hasPrefix(Self.buildingPrefix) {
            let prefix = modelsURL.appendingPathComponent(name).appendingPathComponent("lm").path
            if Self.requiredSuffixes.allSatisfy({ FileManager.default.fileExists(atPath: prefix + $0) }) {
                return prefix
            }
        }
        return nil
    }

    /// Directory-name prefix of a model that is still being written.
    static let buildingPrefix = ".building-"
    static let requiredSuffixes = ["_c_abc.marisa", "_r_xbx.marisa", "_u_abx.marisa", "_u_xbc.marisa"]

    /// Rebuilds the model from the corpus. Call off the main thread.
    @discardableResult
    public func train() -> Bool {
        lock.lock()
        let corpus = (try? String(contentsOf: corpusURL, encoding: .utf8)) ?? ""
        linesSinceTraining = 0
        lock.unlock()
        var lines = corpus.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= Self.minimumLinesForModel else { return false }
        if lines.count > Self.maximumLines {
            lines = Array(lines.suffix(Self.maximumLines))
        }
        let generation = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
        let output = modelsURL.appendingPathComponent(generation, isDirectory: true)
        // Build under a name the lookup skips and rename when every file is written.
        // A key event during the build used to find the half-written files, and loading
        // one aborts the whole helper (2026-11-11).
        let building = modelsURL.appendingPathComponent(Self.buildingPrefix + generation, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: building, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        trainNGram(lines: lines, n: Self.order, baseFilePattern: "lm", outputDir: building.path)
        let builtPrefix = building.appendingPathComponent("lm").path
        guard Self.requiredSuffixes.allSatisfy({ FileManager.default.fileExists(atPath: builtPrefix + $0) }),
              (try? FileManager.default.moveItem(at: building, to: output)) != nil else {
            try? FileManager.default.removeItem(at: building)
            return false
        }
        let prefix = output.appendingPathComponent("lm").path
        lock.lock()
        cachedModelPrefix = .some(prefix)
        lock.unlock()
        // Keep the previous model too. A conversion that looked up its path just before
        // the switch loads the files a moment later (after the 43 MB general model); with
        // the directory already gone that load aborted the whole helper (2026-11-11).
        if let names = try? FileManager.default.contentsOfDirectory(atPath: modelsURL.path) {
            let finished = names.filter { !$0.hasPrefix(Self.buildingPrefix) }.sorted(by: >)
            for name in names where name != generation && !finished.prefix(2).contains(name) {
                try? FileManager.default.removeItem(at: modelsURL.appendingPathComponent(name))
            }
        }
        return true
    }

    /// Deletes the corpus and every model (part of "reset learning data").
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
        cachedModelPrefix = .some(nil)
        cachedEvaluation = nil
        linesSinceTraining = 0
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: measuring the effect (2026-10-15)

    /// A clause the user converted and committed: what was typed and what was chosen.
    public struct EvaluationPair: Equatable, Sendable {
        public var reading: String
        public var text: String
        public var leftContext: String
        public init(reading: String, text: String, leftContext: String) {
            self.reading = reading; self.text = text; self.leftContext = leftContext
        }
    }

    /// Accumulated held-out results: how many committed clauses each strength converted
    /// to exactly what the user chose.
    public struct Evaluation: Codable, Equatable, Sendable {
        public var pairs = 0
        public var matches: [String: Int] = [:]
        public var tunedAlpha: Float = PersonalLanguageModelStore.defaultAlpha
        public var updatedAt = Date(timeIntervalSince1970: 0)

        public func matches(alpha: Float) -> Int { matches[Self.key(alpha)] ?? 0 }
        static func key(_ alpha: Float) -> String { String(format: "%.2f", alpha) }
    }

    public static let defaultAlpha: Float = 0.2
    /// Strengths compared on the user's own commits; 0 is "no personal model".
    public static let candidateAlphas: [Float] = [0, 0.1, 0.2, 0.35]
    static let maximumPendingPairs = 400
    /// Older evidence is halved past this many pairs so the choice follows recent typing.
    static let evaluationHorizon = 2_000

    var pairsURL: URL { directory.appendingPathComponent("pairs.tsv") }
    var evaluationURL: URL { directory.appendingPathComponent("evaluation.json") }
    private var cachedEvaluation: Evaluation?

    /// A conversion the user replaced: the list offered `shown` first and the user picked
    /// row `index` (`chosen`) instead. Kept on this Mac only, to find what to improve.
    public struct Correction: Equatable, Sendable {
        public var reading: String
        public var shown: String
        public var chosen: String
        public var chosenReading: String
        public var leftContext: String
        public var index: Int
        public init(reading: String, shown: String, chosen: String, chosenReading: String, leftContext: String, index: Int) {
            self.reading = reading
            self.shown = shown
            self.chosen = chosen
            self.chosenReading = chosenReading
            self.leftContext = leftContext
            self.index = index
        }
    }

    static let maximumCorrections = 2_000
    var correctionsURL: URL { directory.appendingPathComponent("corrections.tsv") }

    /// Appends one line: day, row, reading, shown, chosen, chosen reading, left context.
    /// The oldest half is dropped once the file holds `maximumCorrections` lines.
    public func appendCorrection(_ correction: Correction, now: Date = Date()) {
        func clean(_ value: String) -> String {
            String(value.map { $0 == "\t" || $0.isNewline ? " " : $0 })
        }
        let reading = clean(correction.reading), shown = clean(correction.shown), chosen = clean(correction.chosen)
        guard !reading.isEmpty, !chosen.isEmpty, shown != chosen,
              reading.count <= 64, shown.count <= 64, chosen.count <= 64 else { return }
        let day = Int(now.timeIntervalSince1970 / 86_400)
        let line = [String(day), String(correction.index), reading, shown, chosen, clean(correction.chosenReading),
                    String(clean(correction.leftContext).suffix(40))].joined(separator: "\t") + "\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            var lines = ((try? String(contentsOf: correctionsURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if lines.count >= Self.maximumCorrections {
                lines.removeFirst(lines.count / 2)
            }
            let data = Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n") + line).utf8)
            try data.write(to: correctionsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: correctionsURL.path)
        } catch {}
    }

    /// Records a committed clause for the next held-out measurement. Pairs are kept only
    /// until the next rebuild: after that the model has seen them, so they would no longer
    /// measure anything.
    public func appendPair(_ pair: EvaluationPair) {
        func clean(_ value: String) -> String {
            String(value.map { $0 == "\t" || $0.isNewline ? " " : $0 })
        }
        let reading = clean(pair.reading), text = clean(pair.text)
        guard !reading.isEmpty, !text.isEmpty, reading.count <= 64, text.count <= 64 else { return }
        let line = [reading, text, String(clean(pair.leftContext).suffix(40))].joined(separator: "\t") + "\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try prepareDirectory()
            if !FileManager.default.fileExists(atPath: pairsURL.path) {
                FileManager.default.createFile(atPath: pairsURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: pairsURL)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            // Roughly maximumPendingPairs lines; more add nothing to one measurement.
            guard size < UInt64(Self.maximumPendingPairs * 120) else { return }
            try handle.write(contentsOf: Data(line.utf8))
        } catch {}
    }

    /// Returns and deletes the pending pairs.
    public func takePairs() -> [EvaluationPair] {
        lock.lock()
        defer { lock.unlock() }
        let raw = (try? String(contentsOf: pairsURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: pairsURL)
        let pairs: [EvaluationPair] = raw.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { return nil }
            return EvaluationPair(reading: fields[0], text: fields[1], leftContext: fields[2])
        }
        return Array(pairs.suffix(Self.maximumPendingPairs))
    }

    public func evaluation() -> Evaluation {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEvaluation { return cachedEvaluation }
        let loaded = (try? Data(contentsOf: evaluationURL)).flatMap { try? JSONDecoder().decode(Evaluation.self, from: $0) } ?? Evaluation()
        cachedEvaluation = loaded
        return loaded
    }

    /// Strength used by the automatic setting.
    public var tunedAlpha: Float { evaluation().tunedAlpha }

    /// Adds one measurement (matches per strength over `pairs` clauses) and re-tunes.
    @discardableResult
    public func record(pairs: Int, matches: [Float: Int], now: Date = Date()) -> Evaluation {
        var next = evaluation()
        if next.pairs + pairs > Self.evaluationHorizon {
            next.pairs /= 2
            next.matches = next.matches.mapValues { $0 / 2 }
        }
        next.pairs += pairs
        for (alpha, count) in matches {
            next.matches[Evaluation.key(alpha), default: 0] += count
        }
        next.tunedAlpha = Self.tune(next)
        next.updatedAt = now
        lock.lock()
        defer { lock.unlock() }
        if (try? prepareDirectory()) != nil, let data = try? JSONEncoder().encode(next) {
            try? data.write(to: evaluationURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: evaluationURL.path)
        }
        cachedEvaluation = next
        return next
    }

    /// Leaves the measured default unless another strength is clearly better on enough
    /// of the user's own clauses: a couple of lucky clauses must not move it.
    static func tune(_ evaluation: Evaluation) -> Float {
        guard evaluation.pairs >= 50 else { return defaultAlpha }
        let baseline = evaluation.matches(alpha: defaultAlpha)
        let margin = max(2, Int((Double(evaluation.pairs) * 0.02).rounded(.up)))
        let best = candidateAlphas.max { lhs, rhs in
            let l = evaluation.matches(alpha: lhs), r = evaluation.matches(alpha: rhs)
            // Ties prefer the default, then the weaker strength.
            return l != r ? l < r : (lhs == defaultAlpha ? false : (rhs == defaultAlpha ? true : lhs > rhs))
        } ?? defaultAlpha
        return evaluation.matches(alpha: best) - baseline >= margin ? best : defaultAlpha
    }

    // MARK: base model

    /// SHA-256 of the general model published with azooKey (Miwa-Keita/base_n5_lm).
    static let baseModelHashes: [String: String] = [
        "_c_abc.marisa": "ab9cfb9b4231b1187934109776339001a9cb089a9d0fa8ed160c79508c8783a3",
        "_r_xbx.marisa": "f9594d23e2f15a8e6d51811f15b23e23bfc7cefd24b8b1c06f3f0366ce5bf555",
        "_u_abx.marisa": "6656bb6bea01f75a2156009b7b104adbd6bf897cff47635fd907215f2bc727e9",
        "_u_xbc.marisa": "69f43384dc45fd16f45e19cbdf242e67f5f8433168dadfe2012abb7657d38041"
    ]

    nonisolated(unsafe) private static let verifiedBasePrefixes = NSCache<NSString, NSNumber>()  // NSCache is thread-safe

    /// Verified base model prefix inside `resources`, or nil when missing or modified.
    public static func baseModelPrefix(resources: URL) -> String? {
        let prefix = resources.appendingPathComponent("base_n5_lm", isDirectory: true).appendingPathComponent("lm").path
        if let known = verifiedBasePrefixes.object(forKey: prefix as NSString) {
            return known.boolValue ? prefix : nil
        }
        let valid = baseModelHashes.allSatisfy { suffix, expected in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefix + suffix), options: .mappedIfSafe) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
        }
        verifiedBasePrefixes.setObject(NSNumber(value: valid), forKey: prefix as NSString)
        return valid ? prefix : nil
    }
}
