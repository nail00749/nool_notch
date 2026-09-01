import Foundation
import Security

@MainActor
protocol JiraCredentialStoring: AnyObject {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

enum JiraCredentialError: Error, Equatable {
    case keychainStatus(OSStatus)
}

@MainActor
final class KeychainJiraCredentialStore: JiraCredentialStoring {
    static let defaultService = "com.nailuyltyev.NotchApp.jira"
    static let defaultAccount = "personal-access-token"

    private let service: String
    private let account: String

    init(
        service: String = KeychainJiraCredentialStore.defaultService,
        account: String = KeychainJiraCredentialStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func loadToken() throws -> String? {
        var query = itemQuery()
        query[kSecReturnData] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw JiraCredentialError.keychainStatus(status) }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw JiraCredentialError.keychainStatus(errSecDecode)
        }
        return token
    }

    func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(
            itemQuery() as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )

        if status == errSecItemNotFound {
            var attributes = itemQuery()
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw JiraCredentialError.keychainStatus(addStatus)
            }
        } else if status != errSecSuccess {
            throw JiraCredentialError.keychainStatus(status)
        }
    }

    func deleteToken() throws {
        let status = SecItemDelete(itemQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JiraCredentialError.keychainStatus(status)
        }
    }

    private func itemQuery() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}
