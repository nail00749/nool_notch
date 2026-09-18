import Foundation

enum LauncherSearch {
    /// Returns deterministic fuzzy matches. A title match ranks before a subtitle match,
    /// then exact and prefix matches rank before a sparse character match.
    static func ranked(_ items: [LauncherResult], query: String) -> [LauncherResult] {
        let tokens = normalizedTokens(query)
        var candidates: [(result: LauncherResult, score: Int)] = []
        var seen: Set<String> = []

        for item in items {
            guard let score = score(item, tokens: tokens) else { continue }
            guard seen.insert(item.id).inserted else { continue }
            candidates.append((item, score))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            let titleOrder = lhs.result.title.localizedStandardCompare(rhs.result.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.result.id < rhs.result.id
        }.map(\.result)
    }

    private static func score(_ item: LauncherResult, tokens: [String]) -> Int? {
        guard tokens.isEmpty == false else { return 0 }

        let title = normalize(item.title)
        let subtitle = normalize(item.subtitle)
        var total = 0

        for token in tokens {
            if let titleScore = fuzzyScore(token, in: title) {
                total += titleScore
            } else if let subtitleScore = fuzzyScore(token, in: subtitle) {
                // Subtitle matches are useful, but should never displace an equally
                // strong title match.
                total += 100 + subtitleScore
            } else {
                return nil
            }
        }

        return total
    }

    private static func fuzzyScore(_ token: String, in candidate: String) -> Int? {
        guard token.isEmpty == false else { return 0 }
        if candidate == token { return 0 }
        if candidate.hasPrefix(token) { return 4 }

        let words = candidate.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        if words.contains(where: { $0.hasPrefix(token) }) { return 12 }

        var tokenIndex = token.startIndex
        var previousMatch: String.Index?
        var gaps = 0

        for index in candidate.indices {
            guard tokenIndex < token.endIndex else { break }
            guard candidate[index] == token[tokenIndex] else { continue }
            if let previousMatch {
                gaps += candidate.distance(from: previousMatch, to: index) - 1
            } else {
                gaps += candidate.distance(from: candidate.startIndex, to: index)
            }
            previousMatch = index
            token.formIndex(after: &tokenIndex)
        }

        guard tokenIndex == token.endIndex else { return nil }
        return 24 + gaps
    }

    private static func normalizedTokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
            .filter { $0.isEmpty == false }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
