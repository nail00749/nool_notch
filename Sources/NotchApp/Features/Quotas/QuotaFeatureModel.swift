import Combine
import Foundation
import NotchCore

@MainActor
final class QuotaFeatureModel: ObservableObject {
    @Published private(set) var snapshots: [String: QuotaSnapshot]
    @Published private(set) var quotaProviderOrder: [String]
    @Published private(set) var hiddenQuotaProviderIDs: Set<String>
    @Published private(set) var compactQuotaProviderID: String
    @Published private(set) var compactQuotaDisplayMode: CompactQuotaDisplayMode
    @Published private(set) var quotaPanelEdge: QuotaPanelEdge
    @Published private(set) var quotaStackCorner: QuotaStackCorner
    let providers: [any QuotaProvider]
    private let preferences: any AppPreferencesStoring
    private let now: @MainActor () -> Date
    private var quotaRefreshTasks: [String: Task<Void, Never>] = [:]
    private var quotaRefreshedAt: [String: Date] = [:]
    private var isStopped = false

    init(providers: [any QuotaProvider], preferences: any AppPreferencesStoring,
         now: @escaping @MainActor () -> Date = Date.init) {
        self.providers = providers
        self.preferences = preferences
        self.now = now
        let providerIDs = providers.map(\.id)
        let quotaProviderOrder = Self.normalizedQuotaProviderOrder(
            preferences.quotaProviderOrder,
            availableProviderIDs: providerIDs
        )
        var hiddenQuotaProviderIDs = preferences.hiddenQuotaProviderIDs
            .intersection(providerIDs)
        if hiddenQuotaProviderIDs.count >= providerIDs.count,
           let fallback = quotaProviderOrder.first {
            hiddenQuotaProviderIDs.remove(fallback)
        }
        let visibleQuotaProviderIDs = quotaProviderOrder.filter {
            hiddenQuotaProviderIDs.contains($0) == false
        }
        let preferredCompactProviderID = preferences.compactQuotaProviderID
        self.quotaProviderOrder = quotaProviderOrder
        self.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
        self.compactQuotaProviderID = visibleQuotaProviderIDs.contains(preferredCompactProviderID)
            ? preferredCompactProviderID
            : visibleQuotaProviderIDs.first ?? ""
        self.compactQuotaDisplayMode = preferences.compactQuotaDisplayMode
        self.quotaPanelEdge = preferences.quotaPanelEdge
        self.quotaStackCorner = preferences.quotaStackCorner
        self.snapshots = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (
                provider.id,
                QuotaSnapshot.unavailable(
                    providerID: provider.id,
                    providerName: provider.displayName,
                    sourceURL: provider.sourceURL,
                    message: "Обновляю данные…"
                )
            )
        })
        preferences.quotaProviderOrder = quotaProviderOrder
        preferences.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
        preferences.compactQuotaProviderID = compactQuotaProviderID
        preferences.compactQuotaDisplayMode = compactQuotaDisplayMode
        preferences.quotaPanelEdge = quotaPanelEdge
        preferences.quotaStackCorner = quotaStackCorner
        for provider in providers {
            guard let ollamaProvider = provider as? OllamaQuotaProvider else { continue }
            let providerID = ollamaProvider.id
            ollamaProvider.prepare { [weak self] in
                self?.refresh(providerID: providerID)
            }
        }

    }

    func refresh() {
        for provider in visibleQuotaProviders { refresh(provider: provider) }
    }

    func stop() {
        isStopped = true
        quotaRefreshTasks.values.forEach { $0.cancel() }
        quotaRefreshTasks.removeAll()
    }

    deinit { quotaRefreshTasks.values.forEach { $0.cancel() } }

    func snapshot(for providerID: String) -> QuotaSnapshot? {
        snapshots[providerID]
    }

    var orderedQuotaProviders: [any QuotaProvider] {
        let providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        return quotaProviderOrder.compactMap { providersByID[$0] }
    }

    var visibleQuotaProviders: [any QuotaProvider] {
        orderedQuotaProviders.filter { hiddenQuotaProviderIDs.contains($0.id) == false }
    }

    var compactQuotaProviderName: String {
        providers.first(where: { $0.id == compactQuotaProviderID })?.displayName
            ?? "Лимит"
    }

    var compactWeeklyRemainingRatio: Double? {
        weeklyQuotaWindow(for: compactQuotaProviderID)?.remainingRatio
    }

    var shouldEnableQuotaEdgePanel: Bool {
        compactQuotaDisplayMode == .wave
            && visibleQuotaProviders.isEmpty == false
    }

    var shouldEnableQuotaCornerStack: Bool {
        compactQuotaDisplayMode == .stack
            && visibleQuotaProviders.isEmpty == false
    }

    func canHideQuotaProvider(_ providerID: String) -> Bool {
        hiddenQuotaProviderIDs.contains(providerID) == false
            && visibleQuotaProviders.count > 1
    }

    func setQuotaProviderVisible(_ providerID: String, isVisible: Bool) {
        guard providers.contains(where: { $0.id == providerID }) else { return }
        if isVisible {
            hiddenQuotaProviderIDs.remove(providerID)
            refresh(providerID: providerID)
        } else {
            guard canHideQuotaProvider(providerID) else { return }
            hiddenQuotaProviderIDs.insert(providerID)
            if compactQuotaProviderID == providerID,
               let fallback = visibleQuotaProviders.first {
                compactQuotaProviderID = fallback.id
                preferences.compactQuotaProviderID = fallback.id
            }
        }
        preferences.hiddenQuotaProviderIDs = hiddenQuotaProviderIDs
    }

    func moveQuotaProvider(_ providerID: String, by offset: Int) {
        guard let sourceIndex = quotaProviderOrder.firstIndex(of: providerID) else { return }
        let destinationIndex = sourceIndex + offset
        guard quotaProviderOrder.indices.contains(destinationIndex) else { return }
        quotaProviderOrder.swapAt(sourceIndex, destinationIndex)
        preferences.quotaProviderOrder = quotaProviderOrder
    }

    func setCompactQuotaProvider(_ providerID: String) {
        guard visibleQuotaProviders.contains(where: { $0.id == providerID }) else { return }
        compactQuotaProviderID = providerID
        preferences.compactQuotaProviderID = providerID
    }

    func setCompactQuotaDisplayMode(_ mode: CompactQuotaDisplayMode) {
        compactQuotaDisplayMode = mode
        preferences.compactQuotaDisplayMode = mode
    }

    func setQuotaPanelEdge(_ edge: QuotaPanelEdge) {
        quotaPanelEdge = edge
        preferences.quotaPanelEdge = edge
    }

    func setQuotaStackCorner(_ corner: QuotaStackCorner) {
        quotaStackCorner = corner
        preferences.quotaStackCorner = corner
    }

    func canBeginAuthentication(for providerID: String) -> Bool {
        providers.first(where: { $0.id == providerID }) is any QuotaProviderAuthenticating
    }

    func beginAuthentication(for providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) as? any QuotaProviderAuthenticating else {
            return
        }

        provider.beginAuthentication { [weak self] in
            self?.refresh(providerID: providerID)
        }
    }

    private func weeklyQuotaWindow(for providerID: String) -> QuotaWindow? {
        guard let windows = snapshots[providerID]?.windows else { return nil }
        return windows.first {
            $0.label == "7d" && $0.unit == .percentage
        } ?? windows.first {
            $0.label.hasSuffix("· 7d") && $0.unit == .percentage
        }
    }

    private static func normalizedQuotaProviderOrder(
        _ preferredOrder: [String],
        availableProviderIDs: [String]
    ) -> [String] {
        let available = Set(availableProviderIDs)
        var seen: Set<String> = []
        let known = preferredOrder.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        return known + availableProviderIDs.filter { seen.insert($0).inserted }
    }

    private func refresh(provider: any QuotaProvider) {
        guard !isStopped, quotaRefreshTasks[provider.id] == nil else { return }
        quotaRefreshTasks[provider.id] = Task { @MainActor [weak self] in
            let snapshot = await provider.loadSnapshot()
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            self.snapshots[provider.id] = snapshot
            self.quotaRefreshedAt[provider.id] = self.now()
            self.quotaRefreshTasks[provider.id] = nil
        }
    }

    func refreshQuotaProviders(ifOlderThan maximumAge: TimeInterval) {
        let currentDate = now()
        for provider in visibleQuotaProviders {
            if let refreshedAt = quotaRefreshedAt[provider.id],
               currentDate.timeIntervalSince(refreshedAt) < maximumAge {
                continue
            }
            refresh(provider: provider)
        }
    }

    private func refresh(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return
        }
        refresh(provider: provider)
    }

}
