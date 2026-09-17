import Foundation

struct AIChatHistoryConversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var provider: AIChatProviderID
    var modelID: String
    var messages: [AIChatMessage]
    var draft: String
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var draftAttachments: [AIChatAttachment] = []

    enum CodingKeys: String, CodingKey { case id, title, provider, modelID, messages, draft, createdAt, updatedAt, isPinned, draftAttachments }

    var searchableText: String {
        ([title, draft] + messages.map(\.modelText) + draftAttachments.map { $0.name + "\n" + $0.text }).joined(separator: "\n").folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
        return normalizedQuery.isEmpty || searchableText.contains(normalizedQuery)
    }
}

extension AIChatHistoryConversation {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        provider = try values.decode(AIChatProviderID.self, forKey: .provider)
        modelID = try values.decode(String.self, forKey: .modelID)
        messages = try values.decode([AIChatMessage].self, forKey: .messages)
        draft = try values.decode(String.self, forKey: .draft)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        draftAttachments = try values.decodeIfPresent([AIChatAttachment].self, forKey: .draftAttachments) ?? []
    }
}

enum AIChatHistoryDisk {
    static let maximumConversationCount = 100
    static let maximumRawBytes = 18 * 1024 * 1024
    static let maximumFileBytes = 20 * 1024 * 1024

    static func load(url: URL) -> AIChatHistoryLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .success([]) }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue >= 0, size.intValue <= maximumFileBytes else {
                return .corrupt
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumFileBytes else { return .corrupt }
            let conversations = try JSONDecoder().decode([AIChatHistoryConversation].self, from: data)
            guard conversations.count <= maximumConversationCount else { return .corrupt }
            return .success(normalize(conversations))
        } catch {
            return .corrupt
        }
    }

    static func write(_ conversations: [AIChatHistoryConversation], url: URL) -> AIChatHistoryWriteResult {
        do {
            guard conversations.count <= maximumConversationCount,
                  rawByteCount(conversations) <= maximumRawBytes else {
                return .tooLarge
            }
            let data = try JSONEncoder().encode(conversations)
            guard data.count <= maximumFileBytes else { return .tooLarge }
            let fileManager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
            return .success
        } catch {
            return .failure
        }
    }

    static func normalize(_ conversations: [AIChatHistoryConversation]) -> [AIChatHistoryConversation] {
        var seen = Set<UUID>()
        return conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .compactMap { conversation in
                guard seen.insert(conversation.id).inserted else { return nil }
                var normalized = conversation
                normalized.messages = normalized.messages.map { message in
                    var message = message
                    if message.state == .streaming { message.state = .interrupted }
                    return message
                }
                return normalized
            }
    }

    static func rawByteCount(_ conversations: [AIChatHistoryConversation]) -> Int {
        conversations.reduce(0) { partial, conversation in
            partial + conversation.title.lengthOfBytes(using: .utf8)
                + conversation.modelID.lengthOfBytes(using: .utf8)
                + conversation.draft.lengthOfBytes(using: .utf8)
                + conversation.messages.reduce(0) { $0 + $1.text.lengthOfBytes(using: .utf8) + $1.attachments.reduce(0) { $0 + $1.storageBytes } }
                + conversation.draftAttachments.reduce(0) { $0 + $1.storageBytes }
                + 256
        }
    }
}

enum AIChatHistoryLoadResult: Sendable {
    case success([AIChatHistoryConversation])
    case corrupt
}

enum AIChatHistoryWriteResult: Sendable, Equatable {
    case success
    case tooLarge
    case failure
}
