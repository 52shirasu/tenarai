import Foundation
import Core

@objc protocol ConverterServerXPCProtocol {
    func handleCommand(_ data: Data, with reply: @escaping @Sendable (Data?, NSString?) -> Void)
    func ping(_ message: String, with reply: @escaping @Sendable (String) -> Void)
}
final class ReplyBox: @unchecked Sendable {
    var data: Data?
    var failed = false
    let semaphore = DispatchSemaphore(value: 0)
}
func connect() -> NSXPCConnection {
    let c = NSXPCConnection(machServiceName: "local.tenarai.inputmethod.tenarai.Scenario")
    c.remoteObjectInterface = NSXPCInterface(with: ConverterServerXPCProtocol.self)
    c.resume(); return c
}
func send(_ c: NSXPCConnection, _ command: ConverterServerCommand?, oversized: Bool = false) throws -> Bool {
    let box = ReplyBox()
    let p = c.remoteObjectProxyWithErrorHandler { _ in box.failed = true; box.semaphore.signal() } as! ConverterServerXPCProtocol
    let data = oversized ? Data(repeating: 0, count: 262145) : try ConverterServerCodec.encode(command!)
    p.handleCommand(data) { data, error in box.data = data; box.failed = error != nil; box.semaphore.signal() }
    precondition(box.semaphore.wait(timeout: .now() + 10) == .success, "timeout")
    return !box.failed && box.data != nil
}
func check(_ value: Bool) { precondition(value) }
@main struct Checks {
    static func main() throws {
        let first = connect(), second = connect()
        defer { first.invalidate(); second.invalidate() }
        check(try send(first, .openSession(sessionID: "owned", command: .composition(.snapshot))))
        check(try !send(second, .session(sessionID: "owned", command: .composition(.snapshot))))
        check(try send(first, .session(sessionID: "owned", command: .learning(.list))))
        check(try !send(first, nil, oversized: true))
        for n in 1..<8 { check(try send(first, .openSession(sessionID: "s\(n)", command: .composition(.snapshot)))) }
        check(try !send(first, .openSession(sessionID: "overflow", command: .composition(.snapshot))))
        print("PASS: authenticated commands, cross-connection isolation, request size and session limits")
    }
}
