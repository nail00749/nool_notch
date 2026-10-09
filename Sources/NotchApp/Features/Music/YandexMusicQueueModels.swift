import Foundation

struct YandexMusicQueueItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let url: URL
    let originPID: Int32?

    init(id: String, title: String, artist: String, url: URL, originPID: Int32? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.url = url
        self.originPID = originPID
    }
}

struct YandexMusicQueuePlayRequest: Equatable, Sendable {
    let expectedItems: [YandexMusicQueueItem]
    let selected: YandexMusicQueueItem
}

enum YandexMusicQueuePlayResult: Equatable, Sendable {
    case played, queueChanged
    case failed(String)
}

enum YandexMusicQueuePlaybackGate {
    static func isEligible(_ request: YandexMusicQueuePlayRequest) -> Bool {
        guard let pid = request.selected.originPID, pid > 0,
              !request.expectedItems.isEmpty, request.expectedItems.count <= 40,
              request.expectedItems.contains(request.selected),
              request.expectedItems.allSatisfy({ $0.originPID == pid }),
              Set(request.expectedItems.map(\.id)).count == request.expectedItems.count else { return false }
        return request.expectedItems.filter {
            $0.title == request.selected.title && $0.artist == request.selected.artist && $0.url == request.selected.url
        }.count == 1
    }

    static func matches(_ request: YandexMusicQueuePlayRequest, fresh: YandexMusicQueueState, scanPartial: Bool) -> Bool {
        guard isEligible(request), !scanPartial, case let .loaded(items, _) = fresh else { return false }
        // Parser partial can mean the intentional 40-row display cap. Actual AX
        // scan truncation is rejected independently; all visible rows must match.
        return items == request.expectedItems
    }

    static func perform(_ request: YandexMusicQueuePlayRequest, fresh: YandexMusicQueueState, scanPartial: Bool,
                        row: YandexMusicQueueItem?, playButtonCount: Int, action: () -> Bool) -> YandexMusicQueuePlayResult {
        guard matches(request, fresh: fresh, scanPartial: scanPartial), row == request.selected, playButtonCount == 1 else { return .queueChanged }
        return action() ? .played : .failed("Яндекс Музыка не выполнила команду воспроизведения. Обновите очередь и попробуйте снова.")
    }
}

enum YandexMusicQueueState: Equatable, Sendable {
    case idle, loading, permissionRequired, notRunning, closed
    case loaded([YandexMusicQueueItem], partial: Bool)
    case failed(String)
}

/// A bounded, semantic snapshot. No AX handles escape the reader.
struct YandexMusicQueueNode: Sendable {
    var role: String = ""
    var title: String = ""
    var description: String = ""
    var value: String = ""
    var url: URL?
    var children: [YandexMusicQueueNode] = []

    func hasLabel(_ label: String) -> Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) == label
            || description.trimmingCharacters(in: .whitespacesAndNewlines) == label
    }
}

enum YandexMusicQueueParser {
    static func parse(_ root: YandexMusicQueueNode, partial: Bool = false, limit: Int = 40, originPID: Int32? = nil) -> YandexMusicQueueState {
        guard let overlay = findOverlay(root, path: "0", requireHeading: true)
            ?? findOverlay(root, path: "0", requireHeading: false) else { return .closed }
        var items: [YandexMusicQueueItem] = []
        var truncated = partial
        var reachedUpcoming = false
        func visit(_ node: YandexMusicQueueNode, path: String) {
            if node.role == "AXStaticText", node.hasLabel("Далее в очереди") || node.value == "Далее в очереди" {
                reachedUpcoming = true
            }
            // History has the same remove controls, so the explicit upcoming heading
            // is required before any row can be presented as next in the queue.
            let subtree = reachedUpcoming ? descendants(node) : []
            if reachedUpcoming, subtree.contains(where: { $0.role == "AXButton" && $0.hasLabel("Удалить из очереди") }) {
                let links = subtree.filter { $0.role == "AXLink" && isTrackURL($0.url) }
                let hasPlay = subtree.contains { $0.role == "AXButton" && $0.hasLabel("Воспроизведение") }
                if links.count == 1, hasPlay, let link = links.first, let url = link.url {
                    // Find the smallest ancestor containing the remove control, play
                    // control and unique track. Wrapper groups are not row identity.
                    let nestedRow = node.children.contains { child in
                        let nested = descendants(child)
                        return nested.filter { $0.role == "AXLink" && isTrackURL($0.url) }.count == 1
                            && nested.contains { $0.role == "AXButton" && $0.hasLabel("Удалить из очереди") }
                            && nested.contains { $0.role == "AXButton" && $0.hasLabel("Воспроизведение") }
                    }
                    if nestedRow {
                        for (index, child) in node.children.enumerated() { visit(child, path: "\(path).\(index)") }
                        return
                    }
                    if items.count >= max(0, limit) { truncated = true; return }
                    let title = labeledText(link, prefix: "Трек ")
                    guard !title.isEmpty else { return }
                    let artists = subtree.filter { $0.role == "AXLink" && ($0.description.hasPrefix("Артист ") || $0.title.hasPrefix("Артист ")) }
                        .map { labeledText($0, prefix: "Артист ") }.filter { !$0.isEmpty }
                    items.append(.init(id: path, title: title, artist: artists.joined(separator: ", "), url: url, originPID: originPID))
                    return
                }
            }
            for (index, child) in node.children.enumerated() { visit(child, path: "\(path).\(index)") }
        }
        visit(overlay.node, path: overlay.path)
        guard reachedUpcoming else { return .failed("Откройте список «Далее в очереди» в Яндекс Музыке.") }
        return .loaded(items, partial: truncated)
    }

    static func rowItem(_ node: YandexMusicQueueNode, id: String, originPID: Int32) -> YandexMusicQueueItem? {
        let all = descendants(node)
        let links = all.filter { $0.role == "AXLink" && isTrackURL($0.url) }
        guard links.count == 1, let link = links.first, let url = link.url,
              all.contains(where: { $0.role == "AXButton" && $0.hasLabel("Удалить из очереди") }),
              all.contains(where: { $0.role == "AXButton" && $0.hasLabel("Воспроизведение") }) else { return nil }
        let title = labeledText(link, prefix: "Трек ")
        guard !title.isEmpty else { return nil }
        let artists = all.filter { $0.role == "AXLink" && ($0.description.hasPrefix("Артист ") || $0.title.hasPrefix("Артист ")) }
            .map { labeledText($0, prefix: "Артист ") }.filter { !$0.isEmpty }
        return .init(id: id, title: title, artist: artists.joined(separator: ", "), url: url, originPID: originPID)
    }

    private static func findOverlay(_ node: YandexMusicQueueNode, path: String, requireHeading: Bool) -> (node: YandexMusicQueueNode, path: String)? {
        for (index, child) in node.children.enumerated() {
            if let result = findOverlay(child, path: "\(path).\(index)", requireHeading: requireHeading) { return result }
        }
        let all = descendants(node)
        let close = all.contains { $0.role == "AXButton" && $0.hasLabel("Закрыть") }
        let queue = all.contains { $0.role == "AXCheckBox" || $0.role == "AXButton" ? $0.hasLabel("Очередь воспроизведения") && $0.value == "1" : false }
        let heading = all.contains { $0.role == "AXStaticText" && ($0.hasLabel("Далее в очереди") || $0.value == "Далее в очереди") }
        return close && queue && (!requireHeading || heading) ? (node, path) : nil
    }

    private static func descendants(_ node: YandexMusicQueueNode) -> [YandexMusicQueueNode] {
        [node] + node.children.flatMap(descendants)
    }

    private static func isTrackURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "music-application" && url.host == "desktop" && url.path == "/album/track"
    }

    private static func labeledText(_ node: YandexMusicQueueNode, prefix: String) -> String {
        let candidates = [node.description, node.title, node.value]
        if let labeled = candidates.first(where: { $0.hasPrefix(prefix) }) {
            return String(labeled.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return candidates.first(where: { !$0.isEmpty })?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
