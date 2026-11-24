import Core
import Testing

@Test(arguments: ["Unknown session", "Unknown converter session: test-session"])
func missingSessionIsRecoverable(error: String) {
    #expect(ConverterSessionRecovery.requiresNewSession(error))
}

@Test(arguments: ["Session limit", "Invalid request", "Request too large", "Permission denied", "", "Unknown setting"])
func otherErrorsDoNotResetSession(error: String) {
    #expect(!ConverterSessionRecovery.requiresNewSession(error))
}

/// A connection loses its session namespace while three input events are queued.
/// Reopen the missing session, then drain events exactly once and in order.
@MainActor
@Test(arguments: ["Unknown session", "Unknown converter session: test-session"])
func reconnectDrainsQueuedInput(error: String) {
    var retry: (@MainActor @Sendable () -> Void)?
    let queue = OrderedAsyncCommandQueue<Int>(scheduleRetry: { retry = $0 })
    var staleSession = true
    var attempts = 0
    var completed: [Int] = []
    for event in 1...3 {
        queue.enqueue(operation: { finish in
            attempts += 1
            if staleSession {
                if ConverterSessionRecovery.requiresNewSession(error) {
                    staleSession = false
                }
                finish(.retry)
            } else {
                finish(.finish(event))
            }
        }, completion: { completed.append($0) })
    }
    retry?()
    #expect(completed == [1, 2, 3])
    #expect(attempts == 4)
    #expect(queue.count == 0)
}
