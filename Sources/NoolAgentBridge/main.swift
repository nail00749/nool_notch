import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

/// Must match `CodexCLIHookServer.socketPath`: the per-user temporary directory, mode 0700.
private let socketPath: String = {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let directory = length > 0 ? String(cString: buffer) : NSTemporaryDirectory()
    return (directory as NSString).appendingPathComponent("nool-notch.sock")
}()

/// Refuses a socket that another user created or serves, so approvals never come from them.
private func isOwnedByCurrentUser(path: String, descriptor: Int32) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
        return false
    }
    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    return getpeereid(descriptor, &peerUID, &peerGID) == 0 && peerUID == getuid()
}

private func connectToSocket(at path: String) -> Int32? {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }

    var noSignal: Int32 = 1
    setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < maxPathLength else {
        close(descriptor)
        return nil
    }
    _ = withUnsafeMutablePointer(to: &address.sun_path.0) { pointer in
        path.withCString { source in
            strncpy(pointer, source, maxPathLength - 1)
        }
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        close(descriptor)
        return nil
    }
    return descriptor
}

private func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
    data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return true }
        var offset = 0
        while offset < bytes.count {
            let sent = send(descriptor, baseAddress + offset, bytes.count - offset, 0)
            if sent < 0 {
                if errno == EINTR { continue }
                return false
            }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }
}

private func receiveAll(from descriptor: Int32) -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count < 0 {
            if errno == EINTR { continue }
            break
        }
        guard count > 0 else { break }
        result.append(contentsOf: buffer[..<count])
    }
    return result
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.isEmpty == false,
      var payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    exit(0)
}

let arguments = CommandLine.arguments
let source: String = {
    guard let index = arguments.firstIndex(of: "--source"),
          arguments.indices.contains(index + 1) else { return "codex-cli" }
    return arguments[index + 1]
}()
payload["_source"] = source
if payload["cwd"] == nil {
    payload["cwd"] = FileManager.default.currentDirectoryPath
}

guard var data = try? JSONSerialization.data(withJSONObject: payload),
      let descriptor = connectToSocket(at: socketPath) else {
    exit(0)
}
guard isOwnedByCurrentUser(path: socketPath, descriptor: descriptor) else {
    close(descriptor)
    exit(0)
}
// Compact JSON has no raw newlines, so one marks the end of the message. The write side stays open:
// NooL treats the socket closing as the CLI going away and withdraws the pending request.
data.append(0x0A)

let eventName = payload["hook_event_name"] as? String ?? ""
let isBlocking = eventName.caseInsensitiveCompare("PermissionRequest") == .orderedSame
var receiveTimeout = timeval(tv_sec: isBlocking ? 86_400 : 2, tv_usec: 0)
setsockopt(
    descriptor,
    SOL_SOCKET,
    SO_RCVTIMEO,
    &receiveTimeout,
    socklen_t(MemoryLayout<timeval>.size)
)

guard sendAll(data, to: descriptor) else {
    close(descriptor)
    exit(0)
}

let response = receiveAll(from: descriptor)
close(descriptor)

if isBlocking, response.isEmpty == false {
    FileHandle.standardOutput.write(response)
}
