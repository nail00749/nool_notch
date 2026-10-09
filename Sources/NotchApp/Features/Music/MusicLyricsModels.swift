import Foundation

struct MusicLyricsTrack: Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval
    let source: String?

    init?(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot else { return nil }
        let title = snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty, title.count <= 1_000, artist.count <= 1_000 else { return nil }
        id = snapshot.id
        self.title = title
        self.artist = artist
        album = snapshot.album.flatMap { $0.isEmpty ? nil : String($0.prefix(1_000)) }
        duration = snapshot.duration.isFinite && snapshot.duration > 0 ? snapshot.duration : 0
        source = snapshot.applicationBundleIdentifier ?? snapshot.appName
    }
}

struct MusicLyricsLine: Equatable, Identifiable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct MusicLyricsDocument: Equatable, Sendable {
    let plainText: String
    let timedLines: [MusicLyricsLine]

    func activeLineIndex(at time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        return timedLines.lastIndex { $0.time <= time }
    }
}

struct MusicLyricsFailure: Error, Equatable, Sendable {
    let message: String
    let retryAfter: Date?

    init(_ message: String, retryAfter: Date? = nil) {
        self.message = message
        self.retryAfter = retryAfter
    }
}

enum MusicLyricsState: Equatable, Sendable {
    case idle
    case loading
    case loaded(MusicLyricsDocument)
    case notFound
    case instrumental
    case failed(MusicLyricsFailure)
}

enum MusicLyricsParser {
    static let maximumCharacters = 100_000
    static let maximumLines = 2_000

    static func document(plain: String?, synced: String?) throws -> MusicLyricsDocument {
        guard (plain?.count ?? 0) <= maximumCharacters,
              (synced?.count ?? 0) <= maximumCharacters else {
            throw MusicLyricsFailure("Текст песни слишком большой.")
        }
        let rawLines = (synced ?? "").components(separatedBy: .newlines)
        let plainLines = (plain ?? "").components(separatedBy: .newlines)
        guard rawLines.count <= maximumLines, plainLines.count <= maximumLines else {
            throw MusicLyricsFailure("В тексте песни слишком много строк.")
        }
        let offsetPattern = try NSRegularExpression(pattern: #"^\[offset:([+-]?\d+)\]$"#, options: .caseInsensitive)
        let timePattern = try NSRegularExpression(pattern: #"\[(\d{1,4}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        var offset: Double = 0
        for line in rawLines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = offsetPattern.firstMatch(in: line, range: range),
               let valueRange = Range(match.range(at: 1), in: line),
               let value = Double(line[valueRange]), value.isFinite, abs(value) <= 86_400_000 {
                offset = value / 1_000
            }
        }
        var entries: [(time: Double, text: String, order: Int)] = []
        for line in rawLines {
            // All timestamps must form the prefix; a bracket in the lyric itself is ordinary text.
            var end = line.startIndex
            var matches: [NSTextCheckingResult] = []
            for match in timePattern.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line), range.lowerBound == end else { break }
                matches.append(match)
                end = range.upperBound
            }
            guard !matches.isEmpty else { continue }
            let text = String(line[end...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minutesRange = Range(match.range(at: 1), in: line),
                      let secondsRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minutesRange]), let seconds = Double(line[secondsRange]), seconds < 60 else { continue }
                var fraction = 0.0
                if let range = Range(match.range(at: 3), in: line) {
                    fraction = (Double(line[range]) ?? 0) / pow(10, Double(line[range].count))
                }
                // Positive LRC offset advances the display; negative offset delays it.
                let time = minutes * 60 + seconds + fraction - offset
                guard time.isFinite, time <= 86_400 else { continue }
                guard entries.count < maximumLines else { throw MusicLyricsFailure("В тексте песни слишком много строк.") }
                entries.append((max(0, time), text, entries.count))
            }
        }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        let lines = entries.enumerated().map { MusicLyricsLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
        let fallback = lines.map(\.text).joined(separator: "\n")
        let plainText = (plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicLyricsDocument(plainText: plainText.isEmpty ? fallback : plainText, timedLines: lines)
    }
}
