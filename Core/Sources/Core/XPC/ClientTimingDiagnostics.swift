import Foundation

/// Content-free timing statistics for the IME client.
///
/// Input text never reaches persistent logs, which left stalls in real apps
/// undiagnosable. This records only durations and event counts so that the cost of
/// synchronous host-app calls (context reads, document observation) and server round
/// trips can be measured during normal use.
public struct LatencyHistogram: Codable, Sendable, Equatable {
    /// Upper bounds in milliseconds; the last bucket counts everything above.
    public static let boundsMs: [Double] = [1, 2, 5, 10, 20, 50, 100, 200, 500, 1000]
    public var counts: [Int] = Array(repeating: 0, count: LatencyHistogram.boundsMs.count + 1)
    public var maxMs: Double = 0
    public var totalMs: Double = 0

    public init() {}

    public var sampleCount: Int { counts.reduce(0, +) }

    public mutating func record(_ milliseconds: Double) {
        let index = Self.boundsMs.firstIndex { milliseconds < $0 } ?? Self.boundsMs.count
        counts[index] += 1
        maxMs = max(maxMs, milliseconds)
        totalMs += milliseconds
    }

    /// Upper bound of the bucket containing the given quantile (an over-estimate).
    public func quantileUpperBoundMs(_ quantile: Double) -> Double? {
        let total = sampleCount
        guard total > 0 else { return nil }
        let target = Int((Double(total) * quantile).rounded(.up))
        var seen = 0
        for (index, count) in counts.enumerated() {
            seen += count
            if seen >= target {
                return index < Self.boundsMs.count ? Self.boundsMs[index] : maxMs
            }
        }
        return maxMs
    }
}

public struct ClientTimingSnapshot: Codable, Sendable, Equatable {
    public var histograms: [String: LatencyHistogram] = [:]
    public var counters: [String: Int] = [:]
    public var since: Date = Date()
    public init() {}
}

@MainActor
public final class ClientTimingDiagnostics {
    public nonisolated static let key = "tenarai.clientTimingDiagnostics"
    private var snapshot: ClientTimingSnapshot
    private var unsaved = 0
    private let saveEvery: Int
    private let save: (ClientTimingSnapshot) -> Void

    public init(
        saveEvery: Int = 200,
        load: () -> ClientTimingSnapshot? = ClientTimingDiagnostics.loadFromConfig,
        save: @escaping (ClientTimingSnapshot) -> Void = ClientTimingDiagnostics.saveToConfig
    ) {
        self.saveEvery = saveEvery
        self.snapshot = load() ?? ClientTimingSnapshot()
        self.save = save
    }

    public var current: ClientTimingSnapshot { snapshot }

    public func record(_ metric: String, milliseconds: Double) {
        snapshot.histograms[metric, default: LatencyHistogram()].record(milliseconds)
        noteChange()
    }

    public func count(_ counter: String) {
        snapshot.counters[counter, default: 0] += 1
        noteChange()
    }

    /// Measures `body` in milliseconds and records it under `metric`.
    public func measure<T>(_ metric: String, _ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        record(metric, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return result
    }

    public func flush() {
        guard unsaved > 0 else { return }
        unsaved = 0
        save(snapshot)
    }

    private func noteChange() {
        unsaved += 1
        if unsaved >= saveEvery {
            flush()
        }
    }

    public nonisolated static func loadFromConfig() -> ClientTimingSnapshot? {
        guard let data = Config.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ClientTimingSnapshot.self, from: data)
    }

    public nonisolated static func saveToConfig(_ snapshot: ClientTimingSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        Config.set(data, forKey: key)
    }
}
