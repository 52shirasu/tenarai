import Foundation
import Crypto
import Darwin

/// Process-wide, fail-closed guard. Only the dedicated helper may enable inference.
public enum LocalInferenceSecurity {
    public static let expectedModelHash = "29c223d4c23327b80fd13ebb5ab2555057a46317997d5da391584ffbef0db673"
    public static let networkBlocked: Bool = {
        guard URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "ConverterServer",
              let library = dlopen("/usr/lib/libsandbox.dylib", RTLD_NOW),
              let symbol = dlsym(library, "sandbox_init") else { return false }
        typealias Initialize = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let initialize = unsafeBitCast(symbol, to: Initialize.self)
        return "(version 1)(allow default)(deny network*)".withCString { initialize($0, 0, nil) == 0 }
    }()

    /// Hash the same in-memory bytes that are copied to a private model file.
    /// llama never opens the unverified source path, avoiding a hash/open race there.
    private static let approvedModel: (url: URL, handle: FileHandle)? = {
        guard networkDenialVerified() else { return nil }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let source = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ggml-model-Q5_K_M.gguf")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path),
              attributes[.size] as? Int == 73_871_936,
              let data = try? Data(contentsOf: source), modelIsApproved(data) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tenarai-model-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let destination = directory.appendingPathComponent("verified.gguf")
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            let handle = try FileHandle(forReadingFrom: destination)
            try FileManager.default.removeItem(at: directory)
            // Keep only an open read-only descriptor; no named file remains to replace.
            return (URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)"), handle)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }()

    public static var approvedModelURL: URL? { approvedModel?.url }

    public static func networkDenialVerified() -> Bool {
        guard networkBlocked else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return errno == EPERM || errno == EACCES }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == -1 && (errno == EPERM || errno == EACCES)
    }

    public static func modelIsApproved(_ data: Data) -> Bool {
        guard data.count == 73_871_936 else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expectedModelHash
    }
}
