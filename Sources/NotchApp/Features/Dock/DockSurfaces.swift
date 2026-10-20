import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct DockFolderSurface<Content: View>: View {
    @ObservedObject var preferences: DockPreferences
    let element: DockElement
    let interactionChanged: (Bool) -> Void
    @ViewBuilder var child: (DockElement) -> Content

    private var current: DockElement { preferences.items.first { $0.id == element.id } ?? element }
    private var gridHeight: CGFloat {
        let rows = max(1, (current.children.count + 3) / 4)
        return min(330, CGFloat(rows) * 83 + CGFloat(rows - 1) * 16 + 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Название папки", text: Binding(get: { current.title }, set: {
                preferences.rename(id: element.id, title: $0)
            })).textFieldStyle(.plain).font(.system(size: 19, weight: .semibold)).accessibilityLabel("Название папки")
            if current.children.isEmpty {
                Text("Перетащите приложения в эту папку").foregroundStyle(.secondary).font(.system(size: 12))
            }
            if !current.children.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(72), spacing: 12), count: 4), spacing: 16) {
                        ForEach(current.children) { item in child(item) }
                    }.padding(.vertical, 4)
                }.frame(height: gridHeight)
            }
        }.padding(22).frame(width: 370).preferredColorScheme(.dark)
            .onAppear { interactionChanged(true) }.onDisappear { interactionChanged(false) }
    }
}

struct DockCatalogView: View {
    @ObservedObject var preferences: DockPreferences
    @ObservedObject var applications: DockApplicationStore
    let interactionChanged: (Bool) -> Void
    @State private var query = ""
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить в Dock").font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Приложения, виджеты и действия", text: $query).textFieldStyle(.plain).focused($searchFocused)
            }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(DockIntegrationRegistry.integrations.filter { matches($0.title) }, id: \.id) { entry in
                        row(title: entry.title, symbol: entry.symbol,
                            added: preferences.items.contains { $0.integrationID == entry.id }) {
                            _ = preferences.addIntegration(entry.id)
                        }
                    }
                    Divider().padding(.vertical, 7)
                    if applications.isCatalogLoading {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Загрузка приложений…").foregroundStyle(.secondary)
                        }.padding(8)
                    }
                    ForEach(applications.catalog.filter { matches($0.title) }) { app in
                        Button { _ = preferences.addApplication(URL(fileURLWithPath: app.path)) } label: {
                            HStack(spacing: 11) {
                                Image(nsImage: applications.icon(for: app.path)).resizable().frame(width: 28, height: 28)
                                Text(app.title).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: preferences.flattenedApps.contains { $0.applicationPath == app.path } ? "checkmark" : "plus")
                                    .foregroundStyle(.secondary)
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(preferences.flattenedApps.contains { $0.applicationPath == app.path })
                    }
                    if !query.isEmpty, !applications.isCatalogLoading,
                       applications.catalog.allSatisfy({ !matches($0.title) }),
                       DockIntegrationRegistry.integrations.allSatisfy({ !matches($0.title) }) {
                        Text("Ничего не найдено").foregroundStyle(.secondary).padding(14)
                    }
                }
            }.frame(maxHeight: 300)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Приложение…") { choose(directory: false) }
                Button("Файловый стэк…") { choose(directory: true) }
                Spacer()
                Button { _ = preferences.addFolder(name: "Новая папка") } label: { Image(systemName: "folder.badge.plus") }
                    .help("Создать папку приложений")
            }.controlSize(.small)
        }.font(.system(size: 12)).padding(18).frame(width: 350).preferredColorScheme(.dark)
            .task { await applications.loadCatalog() }
            .onAppear { interactionChanged(true); searchFocused = true }
            .onDisappear { interactionChanged(false) }
    }

    private func matches(_ title: String) -> Bool { query.isEmpty || title.localizedCaseInsensitiveContains(query) }

    private func row(title: String, symbol: String, added: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 28, height: 28)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: added ? "checkmark" : "plus").foregroundStyle(.secondary)
            }.padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(added)
    }

    private func choose(directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        if !directory { panel.allowedContentTypes = [.applicationBundle] }
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить"
        panel.begin { result in
            guard result == .OK else { return }
            Task { @MainActor in
                var success = true
                for url in panel.urls {
                    let added = directory ? preferences.addStack(url) : preferences.addApplication(url)
                    success = added && success
                }
                error = success ? nil : "Некоторые элементы уже добавлены или недоступны."
            }
        }
    }
}

struct DockPreviewSurface: View {
    @ObservedObject var service: DockWindowPreviewService
    @Environment(\.dismiss) private var dismiss
    let applicationPath: String
    let title: String
    let interactionChanged: (Bool) -> Void
    var hoverChanged: (Bool) -> Void = { _ in }

    @State private var presentationID = UUID()
    /// Fixed for the whole presentation: a SwiftUI popover attached to a non-activating
    /// panel loses its anchor if its content resizes while snapshots load.
    @State private var layout: Layout

    struct Layout: Equatable {
        var width: CGFloat
        var thumbnailHeight: CGFloat
        var hints: Int
        static let empty = Layout(width: 220, thumbnailHeight: 0, hints: 0)
        var contentHeight: CGFloat {
            (thumbnailHeight > 0 ? thumbnailHeight + 24 : 44) + CGFloat(hints) * 16
        }
    }

    init(service: DockWindowPreviewService, applicationPath: String, title: String,
         interactionChanged: @escaping (Bool) -> Void, hoverChanged: @escaping (Bool) -> Void = { _ in }) {
        self.service = service
        self.applicationPath = applicationPath
        self.title = title
        self.interactionChanged = interactionChanged
        self.hoverChanged = hoverChanged
        let frames = Self.visibleWindowFrames(applicationPath: applicationPath)
        let hints = (service.hasCaptureAccess ? 0 : 1) + (service.hasAccessibilityAccess ? 0 : 1)
        _layout = State(initialValue: Self.layout(frames: frames, hints: hints))
    }

    /// Sized from the application's on-screen windows before anything loads; cheap WindowServer metadata only.
    static func layout(frames: [CGRect], hints: Int) -> Layout {
        let sizes = frames.prefix(6).map { thumbnailSize(image: nil, frame: $0) }
        guard !sizes.isEmpty else {
            return Layout(width: maxThumbnail.width, thumbnailHeight: maxThumbnail.height * 0.76, hints: hints)
        }
        let row = sizes.reduce(0) { $0 + $1.width } + CGFloat(sizes.count - 1) * 10
        return Layout(width: min(row, 640), thumbnailHeight: sizes.map(\.height).max() ?? 0, hints: hints)
    }

    /// `init` runs on every parent update while `@State` keeps the first value, so the
    /// WindowServer query is memoized briefly per application.
    private static var frameCache: (path: String, date: Date, frames: [CGRect])?

    private static func visibleWindowFrames(applicationPath: String) -> [CGRect] {
        if let cache = frameCache, cache.path == applicationPath, Date().timeIntervalSince(cache.date) < 1 {
            return cache.frames
        }
        let frames = queryWindowFrames(applicationPath: applicationPath)
        frameCache = (applicationPath, Date(), frames)
        return frames
    }

    private static func queryWindowFrames(applicationPath: String) -> [CGRect] {
        let pids = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == applicationPath
        }.map(\.processIdentifier)
        return pids.flatMap(DockWindowServerMetadata.windows(for:)).filter {
            $0.isOnScreen && $0.alpha > 0 && $0.frame.width >= 80 && $0.frame.height >= 60
        }.map(\.frame)
    }
    private var ownsPresentation: Bool { service.isPresented(by: presentationID) }
    private var loading: Bool { !ownsPresentation || service.isLoading }
    private var emptyMessage: String {
        if loading { return "Загрузка окон…" }
        if !service.hasCaptureAccess && !service.hasAccessibilityAccess { return "Нужен доступ к окнам" }
        if service.errorMessage != nil { return "Не удалось загрузить окна" }
        return "Нет доступных окон"
    }

    private var windows: [DockWindowPreview] {
        service.isPresented(by: presentationID) ? service.windows : []
    }

    /// Thumbnails keep the window's aspect ratio inside a bounded box; the popover
    /// hugs them instead of reserving a fixed frame.
    static let maxThumbnail = CGSize(width: 260, height: 170)

    static func thumbnailSize(image: CGSize?, frame: CGRect) -> CGSize {
        let source = image.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil } ?? frame.size
        guard source.width > 1, source.height > 1 else { return CGSize(width: 206, height: 130) }
        let scale = min(maxThumbnail.width / source.width, maxThumbnail.height / source.height)
        return CGSize(width: max(96, (source.width * scale).rounded()), height: max(60, (source.height * scale).rounded()))
    }

    /// Window frames decide the card; a late snapshot only fills it. Never taller than the frozen row.
    private func size(of window: DockWindowPreview) -> CGSize {
        let natural = Self.thumbnailSize(image: nil, frame: window.frame)
        guard layout.thumbnailHeight > 0, natural.height > layout.thumbnailHeight else { return natural }
        let scale = layout.thumbnailHeight / natural.height
        return CGSize(width: (natural.width * scale).rounded(), height: layout.thumbnailHeight)
    }

    private var hints: [String] {
        guard layout.hints > 0 else { return [] }
        var result: [String] = []
        if !service.hasCaptureAccess { result.append("Для миниатюр разрешите запись экрана в настройках.") }
        if !service.hasAccessibilityAccess { result.append("Для выбора окна разрешите Универсальный доступ в настройках.") }
        return Array(result.prefix(layout.hints))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if windows.isEmpty {
                VStack(spacing: 6) {
                    if loading { ProgressView().controlSize(.small) }
                    Text(ownsPresentation ? service.errorMessage ?? emptyMessage : emptyMessage)
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(width: layout.width, height: layout.contentHeight - CGFloat(layout.hints) * 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(windows) { window in card(window, size: size(of: window)) }
                    }
                }.frame(width: layout.width, height: layout.contentHeight - CGFloat(layout.hints) * 16, alignment: .topLeading)
            }
            ForEach(hints, id: \.self) { hint in
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(width: layout.width, height: 16, alignment: .leading)
            }
        }.padding(8)
            .frame(width: layout.width + 16, height: layout.contentHeight + 16, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if loading, !windows.isEmpty { ProgressView().controlSize(.mini).padding(12) }
            }
            .preferredColorScheme(.dark)
            .onHover(perform: hoverChanged)
            .accessibilityLabel(title)
            .task(id: applicationPath) {
                await service.show(applicationPath: applicationPath, presentationID: presentationID)
            }
            .onAppear { interactionChanged(true) }
            .onDisappear { service.cancel(presentationID: presentationID); interactionChanged(false) }
    }

    private func card(_ window: DockWindowPreview, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { perform(.activate, on: window) } label: {
                ZStack {
                    if let image = window.image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06))
                        VStack(spacing: 6) {
                            Image(systemName: window.isMinimized ? "minus.rectangle" : "macwindow")
                            Text(window.isMinimized ? "Свёрнуто" : "Без снимка").font(.caption)
                        }.foregroundStyle(.secondary)
                    }
                }.frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 0.6) }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Открыть \(window.title)")
                .disabled(!window.availableActions.contains(.activate))
            HStack(spacing: 4) {
                Text(window.title).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 2)
                Menu {
                    action("Перейти к окну", .activate, window)
                    action("Свернуть", .minimize, window)
                    action("Развернуть", .zoom, window)
                    Divider()
                    action("Левая половина", .leftHalf, window)
                    action("Правая половина", .rightHalf, window)
                    action("На следующий дисплей", .nextDisplay, window)
                    Divider()
                    action("Закрыть окно", .close, window)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help("Действия с окном")
            }.frame(width: size.width, height: 18)
        }
    }

    private func action(_ title: String, _ action: DockWindowAction, _ window: DockWindowPreview) -> some View {
        Button(title) { perform(action, on: window) }
            .disabled(!window.availableActions.contains(action))
    }

    private func perform(_ action: DockWindowAction, on window: DockWindowPreview) {
        Task { @MainActor in
            await service.perform(action, on: window, presentationID: presentationID)
            if action == .activate, service.errorMessage == nil, service.windows.isEmpty { dismiss() }
        }
    }
}

struct DockStackSurface: View {
    @ObservedObject var provider: DockFileStackProvider
    @ObservedObject var preferences: DockPreferences
    let element: DockElement
    let interactionChanged: (Bool) -> Void
    /// Built-in stacks (Downloads) keep their order in preferences instead of element options.
    var sortOverride: Binding<DockStackSort>? = nil
    var styleOverride: Binding<DockStackStyle>? = nil
    /// Subfolders opened inside the stack, like browsing in Finder; the root is the stack folder.
    @State private var trail: [URL] = []
    @State private var selection: String?
    @StateObject private var thumbnails = DockThumbnailLoader()

    private var options: [String: String] {
        preferences.items.first { $0.id == element.id }?.options ?? element.options
    }
    private var sort: DockStackSort {
        if let sortOverride { return sortOverride.wrappedValue }
        return DockStackSort(rawValue: options["sort"] ?? "") ?? .modified
    }
    private var style: DockStackStyle {
        if let styleOverride { return styleOverride.wrappedValue }
        return DockStackStyle(rawValue: options["style"] ?? "") ?? .automatic
    }
    private var resolvedStyle: DockStackStyle {
        let resolved = style.resolved(itemCount: provider.items.count + (provider.hasMore ? 1 : 0),
                                      position: preferences.position)
        // The fan lives in its own transparent window; inside this panel it becomes icons.
        return resolved == .fan ? .grid : resolved
    }
    private var root: URL? { element.directoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private var current: URL? { trail.last ?? root }

    var body: some View {
        panel.preferredColorScheme(.dark)
            .task(id: "\(sort.rawValue)|\(current?.path ?? "")") {
                if let current { await provider.load(directory: current, sort: sort) }
            }
            .onAppear { interactionChanged(true) }
            .onDisappear { provider.cancel(); thumbnails.cancel(); interactionChanged(false) }
    }

    private var panelWidth: CGFloat {
        switch resolvedStyle {
        case .list: 340
        case .columns: 600
        case .gallery: 460
        default: 390
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if provider.isLoading, resolvedStyle != .columns { ProgressView().controlSize(.small) }
            if let error = provider.errorMessage, resolvedStyle != .columns {
                Text(error).foregroundStyle(.orange).font(.caption)
            }
            switch resolvedStyle {
            case .columns:
                if let current {
                    DockStackColumns(provider: provider, root: current, sort: sort).id("\(current.path)|\(sort.rawValue)")
                }
            case .gallery: gallery
            case .list: ScrollView { list }.frame(maxHeight: 360)
            default: ScrollView { icons }.frame(maxHeight: 360)
            }
            if provider.items.isEmpty, !provider.isLoading, provider.errorMessage == nil, resolvedStyle != .columns {
                Text("Папка пуста").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
            }
            Button("Открыть в Finder", action: openInFinder).controlSize(.small)
        }.padding(16).frame(width: panelWidth)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if !trail.isEmpty {
                Button { trail.removeLast(); selection = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless).help("Назад").accessibilityLabel("Назад")
            }
            Text(trail.last?.lastPathComponent ?? element.title).font(.headline).lineLimit(1)
            Spacer()
            Picker("Порядок", selection: Binding(get: { sort }, set: { value in
                if let sortOverride { sortOverride.wrappedValue = value }
                else { preferences.setOption("sort", value: value.rawValue, for: element.id) }
            })) {
                ForEach(DockStackSort.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 150)
            Picker("Вид", selection: Binding(get: { style }, set: { value in
                if let styleOverride { styleOverride.wrappedValue = value }
                else { preferences.setOption("style", value: value.rawValue, for: element.id) }
            })) {
                ForEach(DockStackStyle.allCases) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.menu).frame(width: 118)
        }
    }

    /// Folders open in place (like a Finder window); files and bundles open in their app.
    private func activate(_ file: DockStackFile) {
        if file.isBrowsable { trail.append(file.url); selection = nil }
        else { provider.open(file) }
    }

    private var list: some View {
        LazyVStack(spacing: 2) {
            ForEach(provider.items) { file in
                HStack(spacing: 10) {
                    Image(nsImage: provider.icon(for: file)).resizable().frame(width: 32, height: 32)
                    Text(file.title).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if let date = file.modifiedAt {
                        Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if file.isBrowsable { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                }.padding(6)
                    .dockTapTarget(file.title) { activate(file) }
                    .modifier(DockStackFileActions(provider: provider, file: file))
            }
            more
        }
    }

    private var icons: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 8), count: 4), spacing: 12) {
                ForEach(provider.items) { file in
                    VStack(spacing: 5) {
                        Image(nsImage: provider.icon(for: file)).resizable().frame(width: 52, height: 52)
                        Text(file.title).font(.system(size: 10)).lineLimit(2)
                            .multilineTextAlignment(.center).frame(height: 26, alignment: .top)
                    }.frame(width: 84).padding(.vertical, 4)
                        .dockTapTarget(file.title) { activate(file) }
                        .modifier(DockStackFileActions(provider: provider, file: file))
                }
            }.padding(.vertical, 4)
            more
        }
    }

    /// Finder gallery: a large Quick Look thumbnail of the selection above a filmstrip.
    private var gallery: some View {
        let selected = provider.items.first { $0.id == selection } ?? provider.items.first
        return VStack(spacing: 10) {
            if let selected {
                VStack(spacing: 6) {
                    Group {
                        if let image = thumbnails.image(for: selected.url) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else {
                            Image(nsImage: provider.icon(for: selected)).resizable().scaledToFit().padding(40)
                        }
                    }.frame(width: 428, height: 220)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .onTapGesture(count: 2) { activate(selected) }
                    Text(selected.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let date = selected.modifiedAt {
                        Text(date, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.task(id: selected.id) { await thumbnails.load(selected.url, size: CGSize(width: 428, height: 220)) }
                    .modifier(DockStackFileActions(provider: provider, file: selected))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(provider.items) { file in
                        Image(nsImage: provider.icon(for: file)).resizable().frame(width: 44, height: 44)
                            .padding(4)
                            .background(file.id == selected?.id ? Color.accentColor.opacity(0.45) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { activate(file) }
                            .onTapGesture { selection = file.id }
                            .help(file.title)
                            .modifier(DockStackFileActions(provider: provider, file: file))
                    }
                    if provider.hasMore { Button("Ещё") { Task { await provider.loadMore() } } }
                }.padding(.horizontal, 2)
            }.frame(height: 56)
        }
    }

    @ViewBuilder private var more: some View {
        if provider.hasMore { Button("Показать ещё") { Task { await provider.loadMore() } }.padding(8) }
    }

    private func openInFinder() {
        if let current { NSWorkspace.shared.open(current) }
    }
}

/// Finder column view: each selected folder opens the next column to the right.
private struct DockStackColumns: View {
    let provider: DockFileStackProvider
    let root: URL
    let sort: DockStackSort
    @State private var columns: [Column] = []
    @State private var error: String?

    struct Column: Identifiable {
        let url: URL
        var files: [DockStackFile]
        var selected: String?
        var id: String { url.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            columnView(column, index: index)
                            Divider()
                        }
                    }
                }.onChange(of: columns.count) { _, _ in
                    if let last = columns.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }.frame(height: 320)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        }.task { await open(root, at: 0) }
    }

    private func columnView(_ column: Column, index: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(column.files.prefix(1_000)) { file in
                    HStack(spacing: 7) {
                        Image(nsImage: provider.icon(for: file)).resizable().frame(width: 18, height: 18)
                        Text(file.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 2)
                        if file.isBrowsable { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 7).padding(.vertical, 4)
                        .background(column.selected == file.id ? Color.accentColor.opacity(0.55) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !file.isBrowsable { provider.open(file) } }
                        .onTapGesture { select(file, in: index) }
                        .modifier(DockStackFileActions(provider: provider, file: file))
                }
            }.padding(4)
        }.frame(width: 190).id(column.id)
    }

    private func select(_ file: DockStackFile, in index: Int) {
        guard columns.indices.contains(index) else { return }
        columns[index].selected = file.id
        columns.removeSubrange((index + 1)...)
        if file.isBrowsable { Task { await open(file.url, at: index + 1) } }
    }

    private func open(_ url: URL, at index: Int) async {
        let sort = sort
        do {
            let files = try await Task.detached(priority: .userInitiated) {
                try DockFileStackProvider.read(directory: url, sort: sort)
            }.value
            guard !Task.isCancelled, columns.count >= index else { return }
            columns.removeSubrange(index...)
            columns.append(Column(url: url, files: files))
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = "Не удалось прочитать папку: \(error.localizedDescription)" }
        }
    }
}

/// Quick Look thumbnails for the gallery; generated on demand and kept for a few files.
@MainActor
final class DockThumbnailLoader: ObservableObject {
    @Published private var images: [String: NSImage] = [:]
    private var order: [String] = []
    private var request: QLThumbnailGenerator.Request?

    func image(for url: URL) -> NSImage? { images[url.path] }

    func load(_ url: URL, size: CGSize) async {
        guard images[url.path] == nil else { return }
        cancel()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        self.request = request
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              !Task.isCancelled else { return }
        images[url.path] = representation.nsImage
        order.append(url.path)
        if order.count > 24 { images.removeValue(forKey: order.removeFirst()) }
    }

    func cancel() {
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
    }
}

struct DockStackFileActions: ViewModifier {
    let provider: DockFileStackProvider
    let file: DockStackFile
    var onDragEnd: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Открыть") { provider.open(file) }
                Button("Быстрый просмотр") { provider.quickLook(file) }
                Button("Показать в Finder") { provider.reveal(file) }
            }
            .dockFileDrag(file.url, icon: { provider.icon(for: file) }, onEnd: onDragEnd)
    }
}
