import Core
import Foundation

@main struct TenaraiChecks {
    static func main() async throws {
        let command = ConverterServerCommand.session(sessionID: "test", command: .learning(.delete(key: "domain:test")))
        let roundTrip = try ConverterServerCodec.decodeCommand(from: ConverterServerCodec.encode(command))
        guard case .session("test", .learning(.delete("domain:test"))) = roundTrip else {
            fatalError("learning command codec mismatch")
        }
        let response = ConverterServerResponse(localTendencies: [], snapshot: .empty)
        let restored = try ConverterServerCodec.decodeResponse(from: ConverterServerCodec.encode(response))
        precondition(restored.localTendencies?.isEmpty == true)
        // This must throw before URL validation/network, even with an API key and endpoint set.
        do {
            _ = try await OpenAIClient.sendTextTransformRequest(
                prompt: "synthetic test", modelName: "test", apiKey: "synthetic", apiEndpoint: "invalid-url")
            fatalError("external inference unexpectedly allowed")
        } catch LocalOnlyError.externalInferenceDisabled { }
        print("PASS: learning XPC command/response round trip and external-inference rejection")
    }
}
