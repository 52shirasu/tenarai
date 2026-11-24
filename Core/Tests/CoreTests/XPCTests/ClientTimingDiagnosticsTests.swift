@testable import Core
import Foundation
import Testing

@Test func histogramBucketsAndQuantiles() {
    var histogram = LatencyHistogram()
    for value in [0.5, 1.5, 3, 3, 7, 15, 40, 90, 150, 2500] {
        histogram.record(value)
    }
    #expect(histogram.sampleCount == 10)
    #expect(histogram.counts == [1, 1, 2, 1, 1, 1, 1, 1, 0, 0, 1])
    #expect(histogram.maxMs == 2500)
    #expect(histogram.quantileUpperBoundMs(0.5) == 10)
    #expect(histogram.quantileUpperBoundMs(1.0) == 2500)
    #expect(LatencyHistogram().quantileUpperBoundMs(0.5) == nil)
}

@MainActor
@Test func diagnosticsSaveEveryNChangesAndOnFlush() {
    var saved: [ClientTimingSnapshot] = []
    let diagnostics = ClientTimingDiagnostics(saveEvery: 3, load: { nil }, save: { saved.append($0) })
    diagnostics.record("keyRoundTrip", milliseconds: 4)
    diagnostics.count("timeout")
    #expect(saved.isEmpty)
    diagnostics.record("contextFetch", milliseconds: 0.2)
    #expect(saved.count == 1)
    diagnostics.flush()
    #expect(saved.count == 1, "nothing new to save")
    diagnostics.count("timeout")
    diagnostics.flush()
    #expect(saved.last?.counters["timeout"] == 2)
    #expect(saved.last?.histograms["keyRoundTrip"]?.sampleCount == 1)
}

@MainActor
@Test func diagnosticsSnapshotContainsNoText() throws {
    var saved: ClientTimingSnapshot?
    let diagnostics = ClientTimingDiagnostics(saveEvery: 1, load: { nil }, save: { saved = $0 })
    let value = diagnostics.measure("documentObservation") { "誤変換が多い" }
    #expect(value == "誤変換が多い")
    let json = try String(data: JSONEncoder().encode(#require(saved)), encoding: .utf8) ?? ""
    #expect(!json.contains("誤変換"))
    #expect(json.contains("documentObservation"))
}
