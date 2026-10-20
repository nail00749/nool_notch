import Foundation

/// Presets contain semantic modes and stable display UUIDs, never session display IDs.
struct DisplayPresetStore {
    static let key = "displays.presets.v1"
    let defaults: UserDefaults

    func load() -> [DisplayPreset] {
        guard let data = defaults.data(forKey: Self.key),
              let presets = try? JSONDecoder().decode([DisplayPreset].self, from: data) else { return [] }
        var ids = Set<UUID>()
        return presets.filter { ids.insert($0.id).inserted && Self.validName($0.name) != nil }
    }

    func save(_ presets: [DisplayPreset]) throws {
        defaults.set(try JSONEncoder().encode(presets), forKey: Self.key)
    }

    static func validName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 80 ? value : nil
    }
}
