import Darwin
import Foundation

/// A bounded local stdin transport. Broken peers return an error without changing
/// the app-wide SIGPIPE disposition. The lock serializes writes with close/deinit.
final class MediaRemoteCommandChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func make() throws -> (writer: MediaRemoteCommandChannel, reader: FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw posixError() }
        do {
            var enabled: Int32 = 1
            guard setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw posixError() }
            // A stuck helper must not block the main actor in a command write.
            let flags = fcntl(descriptors[0], F_GETFL)
            guard flags >= 0, fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0 else { throw posixError() }
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw posixError() }
            }
            return (MediaRemoteCommandChannel(descriptor: descriptors[0]),
                    FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
        } catch {
            descriptors.forEach { _ = Darwin.close($0) }
            throw error
        }
    }

    @discardableResult
    func write(line: String) -> Bool {
        guard !line.contains("\n"), !line.contains("\r") else { return false }
        let data = Data((line + "\n").utf8)
        guard data.count <= 256 else { return false }
        return lock.withLock {
            guard descriptor >= 0 else { return false }
            return data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                    if written > 0 { offset += written; continue }
                    if written < 0, errno == EINTR { continue }
                    // Also close on backpressure/partial commands; EOF shuts down
                    // the helper rather than leaving half a command in its stream.
                    closeLocked()
                    return false
                }
                return true
            }
        }
    }

    func close() { lock.withLock { closeLocked() } }

    private func closeLocked() {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    deinit { close() }
}
