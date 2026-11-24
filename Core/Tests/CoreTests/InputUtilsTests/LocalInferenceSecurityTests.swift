import Foundation
import Testing
@testable import Core

@Test func localInferenceRejectsUntrustedModelBytes() {
    #expect(!LocalInferenceSecurity.modelIsApproved(Data()))
    #expect(!LocalInferenceSecurity.modelIsApproved(Data("GGUFbadmodel".utf8)))
    #expect(!LocalInferenceSecurity.modelIsApproved(Data(repeating: 0, count: 73_871_936)))
    // Unit-test runners cannot activate the helper-only gate.
    #expect(LocalInferenceSecurity.approvedModelURL == nil)
}
