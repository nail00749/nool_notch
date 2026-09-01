import Foundation

@MainActor
protocol QuotaProviderAuthenticating {
    func beginAuthentication(onUpdate: @escaping @MainActor () -> Void)
}
