import Foundation
import NotchCore

struct DemoQuotaProvider: QuotaProvider {
    let id: String
    let displayName: String
    let sourceURL: URL?
    private let snapshot: QuotaSnapshot

    func loadSnapshot() async -> QuotaSnapshot {
        snapshot
    }

    static let ollama = DemoQuotaProvider(
        id: "ollama-cloud",
        displayName: "Ollama Cloud",
        sourceURL: URL(string: "https://ollama.com/settings"),
        snapshot: QuotaSnapshot(
            providerID: "ollama-cloud",
            providerName: "Ollama Cloud",
            windows: [
                QuotaWindow(
                    id: "session",
                    label: "5h",
                    limit: 100,
                    remaining: 74,
                    resetAt: Date().addingTimeInterval(3 * 60 * 60 + 42 * 60),
                    unit: .credits
                ),
                QuotaWindow(
                    id: "weekly",
                    label: "7d",
                    limit: 1000,
                    remaining: 806,
                    resetAt: Date().addingTimeInterval(5 * 24 * 60 * 60 + 2 * 60 * 60),
                    unit: .credits
                )
            ],
            connection: .stale,
            updatedAt: Date(),
            sourceURL: URL(string: "https://ollama.com/settings"),
            message: "Демо-данные. Точные числа будут читать из аккаунта Ollama Cloud."
        )
    )

    static let all: [any QuotaProvider] = [ollama]
}
