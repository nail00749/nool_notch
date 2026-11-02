import CryptoKit
import Foundation
import Security

enum NooLLinkKeychain {
    static func load(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NooLLinkError.keychain }
        return data
    }

    static func save(_ data: Data, account: String) throws {
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw NooLLinkError.keychain }
        } else if status != errSecSuccess { throw NooLLinkError.keychain }
    }

    static func delete(_ account: String) throws {
        let result = SecItemDelete(query(account) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw NooLLinkError.keychain }
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "app.nool.link", kSecAttrAccount: account]
    }

    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw NooLLinkError.identity }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct NooLLinkIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let fingerprint: String

    private struct Stored: Codable { let p12: Data; let password: String }

    static func loadOrCreate() throws -> NooLLinkIdentity {
        let stored: Stored
        if let data = try NooLLinkKeychain.load("tls-identity") {
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } else {
            stored = try generate()
            try NooLLinkKeychain.save(JSONEncoder().encode(stored), account: "tls-identity")
        }
        return try imported(stored)
    }

    /// Used by isolated transport verification; never writes to the user's Keychain.
    @available(macOS 15.0, *)
    static func ephemeral() throws -> NooLLinkIdentity {
        try imported(generate())
    }

    private static func imported(_ stored: Stored) throws -> NooLLinkIdentity {
        var imported: CFArray?
        var options: [CFString: Any] = [kSecImportExportPassphrase: stored.password]
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly] = true }
        else { options[kSecUseDataProtectionKeychain] = true }
        guard SecPKCS12Import(stored.p12 as CFData,
                              options as CFDictionary,
                              &imported) == errSecSuccess,
              let items = imported as? [[CFString: Any]],
              let first = items.first, let value = first[kSecImportItemIdentity] else { throw NooLLinkError.identity }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { throw NooLLinkError.identity }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return NooLLinkIdentity(identity: identity, fingerprint: fingerprint)
    }

    private static func generate() throws -> Stored {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nool-link-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = try NooLLinkKeychain.randomToken()
        let passwordURL = directory.appendingPathComponent("password")
        try Data(password.utf8).write(to: passwordURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordURL.path)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem", "-days", "3650", "-subj", "/CN=NooL Link"], directory: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("key.pem").path)
        try run(["pkcs12", "-export", "-out", "identity.p12", "-inkey", "key.pem", "-in", "cert.pem", "-passout", "file:" + passwordURL.path], directory: directory)
        return Stored(p12: try Data(contentsOf: directory.appendingPathComponent("identity.p12")), password: password)
    }

    private static func run(_ arguments: [String], directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Key generation is bounded by a watchdog, including a stuck subprocess.
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); throw NooLLinkError.identity }
        guard process.terminationStatus == 0 else { throw NooLLinkError.identity }
    }
}
