import Foundation

struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    private enum PrereleaseIdentifier: Equatable, Sendable {
        case numeric(Int)
        case text(String)

        var description: String {
            switch self {
            case .numeric(let value): String(value)
            case .text(let value): value
            }
        }
    }

    let major: Int
    let minor: Int
    let patch: Int
    private let prerelease: [PrereleaseIdentifier]

    init?(_ rawValue: String) {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("v") {
            normalized.removeFirst()
        }
        normalized = String(normalized.split(separator: "+", maxSplits: 1)[0])
        let releaseParts = normalized.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let components = releaseParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]), major >= 0,
              let minor = Int(components[1]), minor >= 0,
              let patch = Int(components[2]), patch >= 0 else { return nil }

        var prerelease: [PrereleaseIdentifier] = []
        if releaseParts.count == 2 {
            let rawIdentifiers = releaseParts[1].split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            guard rawIdentifiers.isEmpty == false else { return nil }
            for rawIdentifier in rawIdentifiers {
                let value = String(rawIdentifier)
                guard value.isEmpty == false,
                      value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                    return nil
                }
                if let number = Int(value) {
                    guard value == "0" || value.hasPrefix("0") == false else { return nil }
                    prerelease.append(.numeric(number))
                } else {
                    prerelease.append(.text(value))
                }
            }
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard prerelease.isEmpty == false else { return core }
        return core + "-" + prerelease.map(\.description).joined(separator: ".")
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            guard left != right else { continue }
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)):
                return left < right
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case (.text(let left), .text(let right)):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

enum AppUpdateAvailability: Equatable, Sendable {
    case updateAvailable
    case upToDate
    case developmentBuild

    init(installed: AppVersion, latest: AppVersion) {
        if installed < latest {
            self = .updateAvailable
        } else if installed == latest {
            self = .upToDate
        } else {
            self = .developmentBuild
        }
    }
}

struct AppRelease: Equatable, Sendable {
    let version: AppVersion
    let title: String
    let notes: String
    let pageURL: URL
    let publishedAt: Date?
}

enum AppUpdateError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "GitHub вернул неожиданный ответ"
        case .httpStatus(let status): "GitHub вернул ошибку HTTP \(status)"
        case .invalidRelease: "Не удалось прочитать данные последнего релиза"
        }
    }
}

protocol AppUpdateHTTPTransport: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class AppUpdateURLSessionTransport: AppUpdateHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        return (data, response)
    }
}

protocol AppReleaseChecking: Sendable {
    func latestRelease() async throws -> AppRelease
}

struct GitHubReleaseClient: AppReleaseChecking, Sendable {
    private struct Response: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/nail00749/nool_notch/releases/latest"
    )!

    private let transport: any AppUpdateHTTPTransport

    init(transport: any AppUpdateHTTPTransport = AppUpdateURLSessionTransport()) {
        self.transport = transport
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 12
        )
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nool-Notch", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw AppUpdateError.httpStatus(response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Response.self, from: data),
              let version = AppVersion(payload.tagName),
              payload.htmlURL.scheme == "https",
              payload.htmlURL.host == "github.com" else {
            throw AppUpdateError.invalidRelease
        }

        let title = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppRelease(
            version: version,
            title: title?.isEmpty == false ? title! : "Nool Notch \(version)",
            notes: notes?.isEmpty == false ? notes! : "Описание релиза отсутствует.",
            pageURL: payload.htmlURL,
            publishedAt: payload.publishedAt
        )
    }
}

@MainActor
final class AppUpdateProvider: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case result(AppRelease, AppUpdateAvailability)
        case failed(String)
    }

    static let homebrewCommand = "brew update && brew upgrade --cask nool-notch"

    @Published private(set) var state: State = .idle
    let installedVersion: AppVersion
    private let checker: any AppReleaseChecking

    init(
        installedVersionString: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0",
        checker: any AppReleaseChecking = GitHubReleaseClient()
    ) {
        installedVersion = AppVersion(installedVersionString) ?? AppVersion("0.0.0")!
        self.checker = checker
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            let release = try await checker.latestRelease()
            state = .result(
                release,
                AppUpdateAvailability(installed: installedVersion, latest: release.version)
            )
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
