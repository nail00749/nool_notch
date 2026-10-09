import SwiftUI

private struct WorkspaceDraft: Equatable {
    var id = UUID()
    var name = ""
    var entries: [WorkspaceEntry] = []
    var windowLayoutID: UUID?

    init() {}

    init(_ workspace: SavedWorkspace) {
        id = workspace.id
        name = workspace.name
        entries = workspace.entries
        windowLayoutID = workspace.windowLayoutID
    }

    var workspace: SavedWorkspace {
        SavedWorkspace(id: id, name: name, entries: entries, windowLayoutID: windowLayoutID)
    }
}

struct WorkspacesEditorView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var layouts: WindowLayoutManager
    let chooseApplications: (@escaping ([URL]) -> Void) -> Void
    let chooseFolders: (@escaping ([URL]) -> Void) -> Void

    @State private var selectedID: UUID?
    @State private var draft = WorkspaceDraft()
    @State private var website = "https://"
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(NotchPalette.separator)
            editor
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(NotchPalette.surface)
        .foregroundStyle(NotchPalette.text)
        .tint(NotchPalette.accent)
        .onAppear {
            if selectedID == nil, let first = store.workspaces.first { select(first) }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Пространства", systemImage: "square.grid.2x2")
                    .font(.system(size: 14, weight: .bold, design: .default))
                Spacer()
                Button(action: create) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Новое рабочее пространство")
                    .accessibilityLabel("Новое рабочее пространство")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(store.workspaces) { workspace in
                        Button { select(workspace) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "square.grid.2x2.fill")
                                    .foregroundStyle(selectedID == workspace.id ? NotchPalette.accent : NotchPalette.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text("\(workspace.entries.count) элементов")
                                        .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 11).frame(height: 48)
                            .background(selectedID == workspace.id ? NotchPalette.raised : .clear,
                                        in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }

            Text("До 20 пространств")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                .padding(.horizontal, 14).padding(.bottom, 12)
        }
        .frame(width: 210)
        .background(NotchPalette.raised.opacity(0.35))
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                SettingsCard(title: "Название", icon: "character.cursor.ibeam") {
                    TextField("Например, Работа", text: $draft.name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(NotchPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(NotchPalette.separator) }
                }
                SettingsCard(title: "Что открыть", icon: "plus.square.on.square") { entriesSection }
                SettingsCard(title: "Раскладка окон", icon: "rectangle.3.group") { layoutSection }
                if let message { status(message) }
                if let report = store.lastLaunchReport { status(report.summary) }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedID == nil ? "Новое пространство" : "Редактирование")
                    .font(.system(size: 18, weight: .bold, design: .default))
                Text("Приложения, папки и сайты откроются по порядку.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
            }
            Spacer()
            if selectedID != nil {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.bordered).help("Удалить")
            }
            Button("Сохранить", action: save)
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.entries.isEmpty)
        }
    }

    private var entriesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Приложения…") {
                    chooseApplications { append($0.compactMap(WorkspaceEntry.application)) }
                }
                Button("Папки…") {
                    chooseFolders { append($0.compactMap(WorkspaceEntry.folder)) }
                }
                Spacer()
                Text("\(draft.entries.count)/\(SavedWorkspace.maximumEntries)")
                    .font(.system(size: 10, design: .default)).foregroundStyle(NotchPalette.secondary)
            }
            HStack(spacing: 8) {
                TextField("https://example.com", text: $website)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 34)
                    .background(NotchPalette.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(NotchPalette.separator) }
                Button("Добавить сайт", action: addWebsite)
                    .disabled(draft.entries.count >= SavedWorkspace.maximumEntries)
            }
            if draft.entries.isEmpty {
                Text("Добавьте хотя бы один элемент. Поддерживаются приложения, папки и сайты HTTP/HTTPS.")
                    .font(.system(size: 11)).foregroundStyle(NotchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(draft.entries) { entry in
                        HStack(spacing: 9) {
                            Image(systemName: symbol(for: entry.kind))
                                .foregroundStyle(NotchPalette.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Text(kindTitle(entry.kind)).font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { draft.entries.removeAll { $0.id == entry.id } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless).accessibilityLabel("Удалить \(entry.title)")
                        }
                        .padding(.horizontal, 10).frame(height: 42)
                        .background(NotchPalette.surface.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("После запуска", selection: $draft.windowLayoutID) {
                Text("Не применять раскладку").tag(UUID?.none)
                ForEach(layouts.layouts) { layout in Text(layout.name).tag(Optional(layout.id)) }
            }
            .pickerStyle(.menu)
            Text("Раскладка применяется один раз после запуска приложений. Запрос доступа появляется только в окне раскладок.")
                .font(.system(size: 10)).foregroundStyle(NotchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(NotchPalette.text.opacity(0.85))
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(NotchPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
    }

    private func create() {
        selectedID = nil
        draft = WorkspaceDraft()
        message = nil
    }

    private func select(_ workspace: SavedWorkspace) {
        selectedID = workspace.id
        draft = WorkspaceDraft(workspace)
        message = nil
    }

    private func append(_ entries: [WorkspaceEntry]) {
        let available = max(0, SavedWorkspace.maximumEntries - draft.entries.count)
        draft.entries.append(contentsOf: entries.prefix(available))
        if entries.count > available { message = "В одном пространстве может быть не более 20 элементов." }
    }

    private func addWebsite() {
        guard draft.entries.count < SavedWorkspace.maximumEntries else { return }
        guard let entry = WorkspaceEntry.website(website) else {
            message = "Введите полный адрес сайта с http:// или https:// без логина и пароля."
            return
        }
        draft.entries.append(entry)
        website = "https://"
        message = nil
    }

    private func save() {
        switch store.save(draft.workspace) {
        case .saved:
            selectedID = draft.id
            message = "Рабочее пространство сохранено. Найдите его по названию в Launcher."
        case .rejected(let reason): message = reason
        }
    }

    private func remove() {
        guard let selectedID else { return }
        store.remove(id: selectedID)
        if let first = store.workspaces.first { select(first) } else { create() }
    }

    private func symbol(for kind: WorkspaceEntry.Kind) -> String {
        switch kind { case .application: "app"; case .folder: "folder"; case .website: "globe" }
    }

    private func kindTitle(_ kind: WorkspaceEntry.Kind) -> String {
        switch kind { case .application: "Приложение"; case .folder: "Папка"; case .website: "Сайт" }
    }
}
