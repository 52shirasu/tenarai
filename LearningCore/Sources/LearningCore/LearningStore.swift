import Foundation
import CryptoKit

/// Local storage only. Does not collect input, perform inference, or use the network.
/// The host must call purgeExpired periodically and before scheduling learning.
public actor LearningStore {
    public enum Origin: String, Codable, Sendable { case typed, pasted, unknown }
    public enum Kind: String, Codable, Sendable { case domain, vocabulary, spelling, tone }

    public struct Observation: Sendable {
        public let key: String
        public let kind: Kind
        public let value: String
        public init(key: String, kind: Kind, value: String) {
            self.key = key; self.kind = kind; self.value = value
        }
    }

    public struct Tendency: Codable, Equatable, Sendable {
        public let key: String
        public let kind: Kind
        public var value: String
        public var evidence: Double

        public init(key: String, kind: Kind, value: String, evidence: Double) {
            self.key = key; self.kind = kind; self.value = value; self.evidence = evidence
        }
    }

    public struct Job: Codable, Sendable {
        public let id: UUID
        public let generation: UUID
        public let text: String
        public let origin: Origin
        public let savedAt: Date
        public let expiresAt: Date
    }

    private struct State: Codable {
        var version = 1
        var generation = UUID()
        var jobs: [Job] = []
        var tendencies: [String: Tendency] = [:]
        var recentPasteHashes: [String] = []
        var spellingVotes: [String: [String: Double]]?
        var manualOverrides: Set<String>?
    }

    public enum StoreError: Error { case unsupportedVersion, invalidObservation, capacityExceeded }
    public static let retention: TimeInterval = 24 * 60 * 60
    private let file: URL
    private var state: State
    private let maxPendingBytes: Int

    /// Bounded pending storage is a conservative implementation default, not a performance promise.
    public init(directory: URL, now: Date = Date(), maxPendingBytes: Int = 1_048_576, discardPending: Bool = false) throws {
        self.file = directory.appendingPathComponent("learning.json")
        self.maxPendingBytes = maxPendingBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var protectedDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(resourceValues)
        var loaded = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
        guard loaded.version == 1 else { throw StoreError.unsupportedVersion }
        loaded.jobs.removeAll { discardPending || $0.expiresAt <= now }
        // Older files did not distinguish manually edited spellings. Preserve them
        // conservatively instead of letting a new vote overwrite a previous edit.
        if loaded.manualOverrides == nil {
            loaded.manualOverrides = Set(loaded.tendencies.values.filter { $0.kind == .spelling }.map(\.key))
        }
        // Purge before exposing data after restart. Failure is propagated, never silently ignored.
        try Self.persist(loaded, to: file)
        state = loaded
    }

    private static func persist(_ value: State, to file: URL) throws {
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func commit(_ next: State) throws {
        try Self.persist(next, to: file)
        state = next
    }

    /// Receiving the same still-pending text does not extend its deadline.
    @discardableResult
    public func enqueue(_ text: String, origin: Origin, now: Date = Date()) throws -> Job {
        try purgeExpired(now: now)
        if let existing = state.jobs.first(where: { $0.text == text && $0.origin == origin }) {
            return existing
        }
        guard !text.isEmpty, text.utf8.count <= maxPendingBytes,
              state.jobs.reduce(0, { $0 + $1.text.utf8.count }) <= maxPendingBytes - text.utf8.count
        else { throw StoreError.capacityExceeded }
        let job = Job(id: UUID(), generation: state.generation, text: text, origin: origin,
                      savedAt: now, expiresAt: now.addingTimeInterval(Self.retention))
        var next = state
        next.jobs.append(job)
        try commit(next)
        return job
    }

    public func pending(now: Date = Date()) throws -> [Job] {
        try purgeExpired(now: now)
        return state.jobs
    }

    public func purgeExpired(now: Date = Date()) throws {
        var next = state
        next.jobs.removeAll { $0.expiresAt <= now }
        if next.jobs.count != state.jobs.count { try commit(next) }
    }

    /// Failure leaves the original immutable deadline intact.
    public func failed(_ job: Job, now: Date = Date()) throws {
        try purgeExpired(now: now)
    }

    /// Apply only a still-pending job in the current generation; successful extraction removes raw text.
    @discardableResult
    public func complete(_ job: Job, observations: [Observation], now: Date = Date()) throws -> Bool {
        try purgeExpired(now: now)
        guard job.generation == state.generation,
              let saved = state.jobs.first(where: { $0.id == job.id }) else { return false }
        var next = state
        var seen = Set<String>()
        let digest = SHA256.hash(data: Data(saved.text.utf8)).map { String(format: "%02x", $0) }.joined()
        let repeatedPaste = saved.origin != .typed && next.recentPasteHashes.contains(digest)
        // Bound influence per document. Numeric defaults must be evaluated with real data.
        for observation in observations.prefix(repeatedPaste ? 0 : 64) {
            guard !observation.key.isEmpty, observation.key.count <= 128,
                  !observation.value.isEmpty, observation.value.count <= 256 else {
                throw StoreError.invalidObservation
            }
            guard seen.insert(observation.key).inserted else { continue }
            // Pasted/unknown text is evidence of topic, not of personal spelling preference.
            if saved.origin != .typed && observation.kind == .spelling { continue }
            let weight = saved.origin == .typed ? 1.0 : 0.25
            if let old = next.tendencies[observation.key], old.kind != observation.kind {
                throw StoreError.invalidObservation
            }
            let old = next.tendencies[observation.key]
            var preferredValue = old?.value ?? observation.value
            if observation.kind == .spelling && !(next.manualOverrides ?? []).contains(observation.key) {
                var votes = next.spellingVotes ?? [:]
                var variants = votes[observation.key] ?? old.map { [$0.value: $0.evidence] } ?? [:]
                variants[observation.value] = min(100, (variants[observation.value] ?? 0) + weight)
                preferredValue = variants.max { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
                }?.key ?? preferredValue
                votes[observation.key] = variants
                next.spellingVotes = votes
            }
            next.tendencies[observation.key] = Tendency(
                key: observation.key, kind: observation.kind, value: preferredValue,
                evidence: min(100, (old?.evidence ?? 0) + weight))
        }
        next.jobs.removeAll { $0.id == saved.id }
        if saved.origin != .typed && !repeatedPaste {
            next.recentPasteHashes.append(digest)
            next.recentPasteHashes = Array(next.recentPasteHashes.suffix(256))
        }
        try commit(next)
        return true
    }

    /// Migration to transient learning must not retain legacy queued originals.
    public func discardPending() throws {
        var next = state
        next.jobs.removeAll()
        try commit(next)
    }

    public func generation() -> UUID { state.generation }

    public func tendencies() -> [Tendency] {
        state.tendencies.values.sorted { $0.key < $1.key }
    }

    /// For suspendable hosts: persist extracted tendencies only, never pending input.
    /// Extraction happens before touching state; complete persists only the final state.
    public func learnTransient(_ text: String, origin: Origin, now: Date = Date(), observations supplied: [Observation]? = nil) throws {
        try purgeExpired(now: now)
        guard !text.isEmpty, text.utf8.count <= maxPendingBytes else { throw StoreError.capacityExceeded }
        let observations = supplied ?? LocalExtractor.extract(text, origin: origin)
        let previous = state
        let job = Job(id: UUID(), generation: state.generation, text: text, origin: origin,
                      savedAt: now, expiresAt: now.addingTimeInterval(Self.retention))
        state.jobs.append(job)
        do {
            _ = try complete(job, observations: observations, now: now)
        } catch {
            state = previous
            throw error
        }
    }

    public func edit(key: String, value: String) throws {
        guard !value.isEmpty, value.count <= 256 else { throw StoreError.invalidObservation }
        var next = state
        guard next.tendencies[key] != nil else { return }
        next.tendencies[key]?.value = value
        next.manualOverrides = (next.manualOverrides ?? []).union([key])
        // Old asynchronous work must not overwrite an explicit edit.
        next.generation = UUID()
        next.jobs.removeAll()
        next.recentPasteHashes.removeAll()
        try commit(next)
    }

    public func delete(key: String) throws {
        var next = state
        next.tendencies.removeValue(forKey: key)
        next.spellingVotes?.removeValue(forKey: key)
        next.manualOverrides?.remove(key)
        // Pending raw text has not been classified yet: discard all rather than guess relevance.
        next.jobs.removeAll()
        next.recentPasteHashes.removeAll()
        next.generation = UUID()
        try commit(next)
    }

    public func deleteAll() throws {
        try commit(State())
    }
}
