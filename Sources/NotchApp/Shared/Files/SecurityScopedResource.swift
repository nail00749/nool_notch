import Foundation

/// Owns one balanced security-scoped access for as long as a consumer needs it.
/// A false result also covers ordinary local URLs; it does not imply file access failed.
final class SecurityScopedResource {
    let url: URL
    private var isAccessing: Bool

    init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    func endAccess() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit { endAccess() }
}
