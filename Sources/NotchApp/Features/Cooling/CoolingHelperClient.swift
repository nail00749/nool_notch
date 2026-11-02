import Foundation
import Security
import NoolCoolingCore

/// One reply wins even when an XPC interruption races its timeout.
private final class CoolingReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

@MainActor
protocol CoolingClientTransport: AnyObject {
    func snapshot() async throws -> CoolingSnapshot
    func apply(_ command: CoolingControlRequest) async throws -> CoolingSnapshot
    func heartbeat(_ sessionID: String) async throws
    func release(_ sessionID: String) async throws
    func disconnect()
}

@MainActor
final class CoolingHelperClient: CoolingClientTransport {
    private var connection: NSXPCConnection?

    static let signingTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return team
    }()

    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let team = Self.signingTeam else {
            throw CoolingError.unavailable("Управление требует сборку NooL с подписью разработчика. В этой сборке доступен мониторинг.")
        }
        let connection = NSXPCConnection(machServiceName: CoolingService.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NoolCoolingHelperProtocol.self)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"com.nool.cooling-helper\" and certificate leaf[subject.OU] = \"\(team)\"")
        connection.resume()
        self.connection = connection
        return connection
    }

    func disconnect() { connection?.invalidate(); connection = nil }

    private func request(timeout: TimeInterval = 5, _ operation: (NoolCoolingHelperProtocol, @escaping @Sendable (Data?, String?) -> Void) -> Void) async throws -> Data {
        let connection = try connected()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let reply = CoolingReply(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    reply.finish(.failure(CoolingError.unavailable("Служба охлаждения не ответила. Проверьте разрешение в настройках macOS.")))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    reply.finish(.failure(error))
                }) as? NoolCoolingHelperProtocol else {
                    reply.finish(.failure(CoolingError.unavailable("Служба охлаждения недоступна.")))
                    return
                }
                operation(proxy) { data, error in
                    if let error { reply.finish(.failure(CoolingError.hardware(error))) }
                    else { reply.finish(.success(data ?? Data())) }
                }
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func snapshot() async throws -> CoolingSnapshot {
        try decode(await request { proxy, reply in proxy.snapshot(reply: reply) })
    }

    func apply(_ command: CoolingControlRequest) async throws -> CoolingSnapshot {
        let payload = try JSONEncoder().encode(command)
        return try decode(await request(timeout: 8) { proxy, reply in proxy.apply(payload, reply: reply) })
    }

    func heartbeat(_ sessionID: String) async throws {
        _ = try await request { proxy, reply in proxy.heartbeat(sessionID) { reply(nil, $0) } }
    }

    func release(_ sessionID: String) async throws {
        _ = try await request { proxy, reply in proxy.release(sessionID) { reply(nil, $0) } }
    }

    private func decode(_ data: Data) throws -> CoolingSnapshot {
        guard data.count <= 1_048_576 else { throw CoolingError.unavailable("Слишком большой ответ службы охлаждения.") }
        let snapshot = try JSONDecoder().decode(CoolingSnapshot.self, from: data)
        guard snapshot.protocolVersion == CoolingService.protocolVersion else {
            throw CoolingError.unavailable("Версия службы устарела. Отключите и снова включите управление охлаждением.")
        }
        return snapshot
    }
}
