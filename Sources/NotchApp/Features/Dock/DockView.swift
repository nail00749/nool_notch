import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DockView: View {
    @ObservedObject var feature: DockFeatureModel
    let model: NotchViewModel
    let interactionChanged: (Bool) -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        DockStrip(feature: feature, preferences: feature.prefs, applications: feature.applications,
                  trash: feature.trash, accessibility: feature.accessibility, downloads: feature.downloads,
                  loginItems: feature.loginItems, model: model, modules: model.modules,
                  interactionChanged: interactionChanged, hoverChanged: hoverChanged)
    }
}

private struct DockStrip: View {
    @ObservedObject var feature: DockFeatureModel
    @ObservedObject var preferences: DockPreferences
    @ObservedObject var applications: DockApplicationStore
    @ObservedObject var trash: DockTrashModel
    @ObservedObject var accessibility: DockAccessibilityMonitor
    @ObservedObject var downloads: DockDownloadProgressModel
    @ObservedObject var loginItems: DockLoginItems
    let model: NotchViewModel
    @ObservedObject var modules: AppModuleStore
    let interactionChanged: (Bool) -> Void
    let hoverChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var trashTargeted = false
    @State private var downloadsTargeted = false
    @State private var shownError: String?
    @State private var expandedID: String?
    @State private var previewPath: String?
    @State private var dragID: String?
    @State private var dropTarget: String?
    @State private var groupTarget: String?
    @State private var dwell: Task<Void, Never>?
    @State private var springTask: Task<Void, Never>?
    @State private var springKey: String?
    @State private var folderDropTarget: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewDismissTask: Task<Void, Never>?
    @State private var interactionIDs = Set<String>()
    @State private var dragWatch: Task<Void, Never>?
    /// Pinned order while one of its items is dragged; the gap follows the pointer.
    @State private var liveOrder: [String]?
    /// Gap opened for an application or file arriving from outside the pinned list.
    @State private var insertion: DockInsertion?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cell: CGFloat { DockLayout.cellWidth(scale: preferences.scale) }
    private var spacing: CGFloat { DockLayout.spacing(scale: preferences.scale) }
    private var logicalHeight: CGFloat { DockLayout.contentHeight(showLabels: preferences.showAppLabels) }
    private var height: CGFloat { logicalHeight * preferences.scale }
    private var running: [DockRunningApplication] { feature.unpinnedApplications }
    private var recent: [DockRecentApplication] { feature.recentApplications }
    private var vertical: Bool { preferences.position.isVertical }
    private var edge: Edge { feature.popoverEdge }
    /// The strip side facing the screen interior, where the panel has headroom.
    private var headroomEdge: Edge.Set {
        switch preferences.position {
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }
        private var reorderAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82)
    }
    private var displayedItems: [DockElement] {
        guard let liveOrder else { return preferences.items }
        let byID = Dictionary(preferences.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = liveOrder.compactMap { byID[$0] }
        return ordered.count == preferences.items.count ? ordered : preferences.items
    }
    private var axis: AnyLayout {
        vertical ? AnyLayout(VStackLayout(spacing: spacing)) : AnyLayout(HStackLayout(spacing: spacing))
    }
    private func context(for item: DockElement) -> DockIntegrationContext {
        DockIntegrationContext(model: model, preferences: preferences, interactionChanged: interaction("integration:\(item.id)"),
                               openLauncher: feature.openLauncher, openDisplays: feature.openDisplays)
    }

    var body: some View {
        axis {
            ScrollView(vertical ? .vertical : .horizontal, showsIndicators: false) {
                axis {
                    ForEach(displayedItems) { item in pinnedCell(item) }
                    if !preferences.items.isEmpty, !running.isEmpty || !recent.isEmpty { separator }
                    ForEach(running) { app in
                        otherApplicationCell(path: app.path, title: app.title)
                    }
                    ForEach(recent) { app in
                        otherApplicationCell(path: app.path, title: app.title)
                    }
                }.padding(vertical ? .vertical : .horizontal, 3)
                    .padding(vertical ? .horizontal : .vertical, DockLayout.basePadding * preferences.scale)
                    .animation(reorderAnimation, value: liveOrder)
                    .animation(reorderAnimation, value: insertion)
            }
            // Icons may bounce or magnify into the panel's headroom; only the scroll axis clips.
            .scrollClipDisabled()
            .mask {
                Rectangle().padding(headroomEdge, -DockLayout.headroom(scale: preferences.scale))
            }
            // Like the system Dock: minimized windows, Downloads and Trash after the applications.
            // Adding items, profiles and system Dock recovery live in NooL settings, not on the strip.
            if feature.trailingCellCount > 0 {
                separator
                ForEach(feature.minimizedWindows) { window in trailingCell { minimizedCell(window) } }
                if preferences.showDownloads { trailingCell { downloadsCell } }
                if preferences.showTrash { trailingCell { trashCell } }
            }
        }.padding(vertical ? .vertical : .horizontal, DockLayout.basePadding * preferences.scale)
            .frame(width: vertical ? DockLayout.verticalThickness(scale: preferences.scale) : nil,
                   height: vertical ? nil : DockLayout.height(scale: preferences.scale, showLabels: preferences.showAppLabels))
            .background {
                ZStack {
                    NativePanelBackground(material: .popover)
                    Color.black.opacity(reduceTransparency ? 1 : preferences.opacity * 0.6)
                }.clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15), lineWidth: 0.7) }
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .onHover { hoverChanged($0) }
            .popover(isPresented: Binding(get: { shownError != nil }, set: { if !$0 { shownError = nil } }),
                     arrowEdge: edge) {
                Text(shownError ?? "").font(.system(size: 12)).padding(12).frame(maxWidth: 320)
            }
            .onChange(of: currentError) { _, message in
                shownError = message
                guard let message else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    if shownError == message { shownError = nil }
                }
            }
            .onChange(of: feature.surfaceGeneration) { _, _ in closeSurfaces() }
            .onChange(of: preferences.activeProfileID) { _, _ in feature.closeSurfaces(); closeSurfaces() }
            .onChange(of: preferences.position) { _, _ in closeSurfaces() }
            .onExitCommand { closeSurfaces() }
            .onDisappear { closeSurfaces(); interactionIDs.removeAll(); interactionChanged(false) }
    }

    private var separator: some View {
        Capsule().fill(.white.opacity(0.13)).frame(width: vertical ? 32 : 1, height: vertical ? 1 : 32)
    }
    private var currentError: String? {
        applications.errorMessage ?? trash.errorMessage ?? loginItems.errorMessage ?? feature.errorMessage
    }

    private func pinnedCell(_ item: DockElement) -> some View {
        let length = width(item)
        let gap = cell + spacing
        let leading = insertion == DockInsertion(id: item.id, after: false) ? gap : 0
        let trailing = insertion == DockInsertion(id: item.id, after: true) ? gap : 0
        // The dragged item stays in the strip as an empty slot, like the system Dock.
        let isGap = liveOrder != nil && dragID == item.id
        return element(feature.effectiveElement(item))
            .opacity(isGap ? 0 : 1)
            .frame(width: length / preferences.scale, height: logicalHeight)
            .scaleEffect(preferences.scale)
            .frame(width: length, height: height)
            .modifier(DockPopoverAnchor(isPresented: previewBinding(item.applicationPath), arrowEdge: edge) {
                if let path = item.applicationPath { windowPreview(path: path, title: item.title) }
            })
            // Dwelling on an application or folder groups into it: the target lifts and glows.
            .scaleEffect(groupTarget == item.id ? 1.12 : 1)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(groupTarget == item.id ? 0.16 : 0))
            }
            .animation(reorderAnimation, value: groupTarget)
            .padding(vertical ? .top : .leading, leading)
            .padding(vertical ? .bottom : .trailing, trailing)
            .contentShape(Rectangle())
            .onDrag { beginDrag(item.id) }
            .onDrop(of: [.utf8PlainText, .fileURL], delegate: DockElementDropDelegate(
                item: item, length: vertical ? height : length, vertical: vertical,
                preferences: preferences, applications: applications,
                dragID: $dragID, dropTarget: $dropTarget, groupTarget: $groupTarget,
                liveOrder: $liveOrder, insertion: $insertion, leadingInset: leading,
                commitLiveOrder: commitLiveOrder,
                dwell: $dwell, expand: { expandedID = item.id; previewPath = nil },
                interactionChanged: interaction("drag"), receiveFiles: feature.receiveFiles,
                spring: { spring(item) }))
            .contextMenu { itemMenu(item) }
    }

    /// Running unpinned and recent applications share one section, like the system Dock.
    private func otherApplicationCell(path: String, title: String) -> some View {
        appIcon(path: path, title: title, id: "running:\(path)")
            .frame(width: DockLayout.baseCellWidth, height: logicalHeight)
            .scaleEffect(preferences.scale)
            .frame(width: cell, height: height)
            .modifier(DockPopoverAnchor(isPresented: previewBinding(path), arrowEdge: edge) {
                windowPreview(path: path, title: title)
            })
            .onDrag { beginDrag("running:\(path)") }
            .contextMenu { appMenu(path: path, pinnedID: nil) }
            .onDrop(of: [.fileURL], isTargeted: Binding(get: { springKey == "running:\(path)" }, set: { targeted in
                springTargetChanged("running:\(path)", targeted: targeted) { applications.springOpen(path: path) }
            })) { providers in openFiles(providers, path: path) }
    }

    /// The drag ends when the mouse button is released, not when SwiftUI frees the item
    /// provider: that may happen mid-gesture and must not clear the dragged identifier.
    private func beginDrag(_ id: String) -> NSItemProvider {
        dragID = id
        insertion = nil
        liveOrder = nil
        if preferences.items.contains(where: { $0.id == id }) {
            // AppKit snapshots the drag image right after this returns; empty the slot afterwards.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                guard dragID == id, liveOrder == nil else { return }
                withAnimation(reorderAnimation) { liveOrder = preferences.items.map(\.id) }
            }
        }
        previewPath = nil
        setInteraction("drag", active: true)
        dragWatch?.cancel()
        dragWatch = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(40))
            }
            let point = NSEvent.mouseLocation
            // performDrop runs on mouse-up; give it time to consume the drag first.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            finishDrag(id, at: point)
        }
        return DockDragProvider(id: id)
    }

    /// A pinned item released away from the Dock, outside every NooL window, is removed.
    private func finishDrag(_ id: String, at point: CGPoint) {
        dragWatch = nil
        let unconsumed = dragID == id
        if unconsumed { dragID = nil }
        dropTarget = nil; groupTarget = nil
        dwell?.cancel(); setInteraction("drag", active: false)
        let outside = feature.isOutsideDock(point)
        // Released over the strip but between cells: keep the order the gap showed.
        if unconsumed, liveOrder != nil, !outside { commitLiveOrder(id) }
        withAnimation(reorderAnimation) { liveOrder = nil; insertion = nil }
        guard unconsumed, !id.hasPrefix("running:"), outside,
              !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
        preferences.remove(id: id)
        DockTrashModel.play("dock/poof item off dock.aif")
    }

    /// Moves the dragged pinned item to where the live order shows its gap.
    private func commitLiveOrder(_ id: String) {
        guard let order = liveOrder, order.contains(id) else { return }
        if let next = DockLiveReorder.successor(of: id, in: order) {
            preferences.move(id: id, before: next)
        } else {
            preferences.moveToEnd(id: id)
        }
    }

    private func trailingCell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: DockLayout.baseCellWidth, height: logicalHeight)
            .scaleEffect(preferences.scale)
            .frame(width: cell, height: height)
    }

    private func minimizedCell(_ window: DockMinimizedWindow) -> some View {
        let title = window.title.isEmpty ? "Свёрнутое окно" : window.title
        return VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.12))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.2), lineWidth: 0.7) }
                    .overlay { Image(systemName: "macwindow").font(.system(size: 17)).foregroundStyle(.white.opacity(0.55)) }
                    .frame(width: 40, height: 31)
                Image(nsImage: applications.icon(for: window.applicationPath)).resizable().frame(width: 20, height: 20)
                    .offset(x: 6, y: 6)
            }.frame(width: DockLayout.iconSize, height: DockLayout.iconSize)
            Capsule().fill(.clear).frame(width: 4, height: 3)
            if preferences.showAppLabels {
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .dockTapTarget("Развернуть \(title)") { accessibility.restore(window) }.help(title)
    }

    private var downloadsCell: some View {
        let element = feature.downloadsElement
        return DockSystemIcon(image: NSWorkspace.shared.icon(forFile: element.directoryPath ?? ""), title: element.title,
                              showsLabel: preferences.showAppLabels, progress: downloads.fraction)
            .modifier(DockBounceOnce(trigger: downloads.finishedCount, position: preferences.position))
            .dockTapTarget(element.title) {
                openStack(element, sort: preferences.downloadsSort, style: preferences.downloadsStyle)
            }.help(element.title)
            .background(DockAnchorView(id: element.id, registry: feature.anchors))
            .background(.white.opacity(downloadsTargeted ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
            .popover(isPresented: expansion(element.id), arrowEdge: edge) {
                DockStackSurface(provider: feature.stacks, preferences: preferences, element: element,
                                 interactionChanged: interaction("stack"), sortOverride: $preferences.downloadsSort,
                                 styleOverride: $preferences.downloadsStyle)
            }
            .contextMenu {
                stackMenu(sort: $preferences.downloadsSort, style: $preferences.downloadsStyle)
                Button("Открыть в Finder") {
                    if let path = element.directoryPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            }
            .onChange(of: downloadsTargeted) { _, targeted in
                springTargetChanged(element.id, targeted: targeted) { openInFinder(element) }
            }
            .onDrop(of: [.fileURL], isTargeted: $downloadsTargeted) { providers in
                guard let path = element.directoryPath else { return false }
                return DockFileDrop.load(providers) { urls in feature.receiveFiles(urls, into: path) }
            }
    }

    private var trashCell: some View {
        DockSystemIcon(image: trash.icon, title: "Корзина", showsLabel: preferences.showAppLabels)
            .dockTapTarget("Корзина") { trash.open() }.help("Корзина")
            .background(.white.opacity(trashTargeted ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 12))
            .contextMenu {
                Button("Открыть") { trash.open() }
                Button("Очистить Корзину…") { trash.emptyAfterConfirmation() }
            }
            .onDrop(of: [.utf8PlainText, .fileURL], delegate: DockTrashDropDelegate(targeted: $trashTargeted, drop: dropOnTrash))
            .onAppear { trash.refresh() }
    }

    /// Dock items dragged onto Trash are unpinned; files from Finder or stacks move to Trash.
    private func dropOnTrash(_ providers: [NSItemProvider]) -> Bool {
        if let id = dragID {
            if !id.hasPrefix("running:") {
                preferences.remove(id: id)
                DockTrashModel.play("dock/poof item off dock.aif")
            }
            dragID = nil; dropTarget = nil; groupTarget = nil; liveOrder = nil; insertion = nil
            dwell?.cancel(); setInteraction("drag", active: false)
            return true
        }
        return DockFileDrop.load(providers) { urls in trash.moveToTrash(urls) }
    }

    private func width(_ item: DockElement) -> CGFloat {
        DockLayout.width(span: feature.effectiveElement(item).span, scale: preferences.scale)
    }

    @ViewBuilder private func element(_ item: DockElement) -> some View {
        switch item.kind {
        case .app:
            appIcon(path: item.applicationPath ?? "", title: item.title, id: item.id)
        case .folder:
            DockFolderIcon(element: item, applications: applications).frame(width: DockLayout.iconSize, height: DockLayout.iconSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dockTapTarget(item.title) { toggleExpansion(item.id) }.help(item.title)
                .popover(isPresented: expansion(item.id), arrowEdge: edge) {
                    folder(item)
                }
        case .stack:
            DockActionWidget(symbol: "folder.fill", title: item.title) {
                openStack(item, sort: stackBinding("sort", item: item, fallback: DockStackSort.modified).wrappedValue,
                          style: stackBinding("style", item: item, fallback: DockStackStyle.automatic).wrappedValue)
            }
                .background(DockAnchorView(id: item.id, registry: feature.anchors))
                .popover(isPresented: expansion(item.id), arrowEdge: edge) {
                    DockStackSurface(provider: feature.stacks, preferences: preferences,
                                     element: item, interactionChanged: interaction("stack"))
                }
        case .integration:
            if let entry = DockIntegrationRegistry.integration(item.integrationID) {
                if entry.isAvailable(model) { entry.content(item, context(for: item)).id("\(item.id):\(feature.surfaceGeneration)") }
                else {
                    VStack(spacing: 5) {
                        Image(systemName: entry.symbol).font(.system(size: 20))
                        if item.span > 1 { Text("Модуль выключен").font(.system(size: 9)) }
                    }.foregroundStyle(.white.opacity(0.3)).help("\(entry.title): модуль выключен")
                }
            }
        }
    }

    private func appIcon(path: String, title: String, id: String, inFolder: Bool = false) -> some View {
        let launching = preferences.animateLaunch && applications.launching.contains(path)
        return DockApplicationIcon(applications: applications, path: path, title: title,
                                   magnification: dragID == nil ? preferences.magnification : 0,
                                   showsLabel: preferences.showAppLabels && !inFolder,
                                   badge: preferences.showBadges ? accessibility.badges[path] : nil,
                                   isLaunching: launching, dimsHidden: preferences.dimHiddenApplications,
                                   position: preferences.position) {
            activate(path: path)
        }
        .onHover { hovered in
            previewTask?.cancel()
            previewDismissTask?.cancel()
            if !hovered, previewPath == path {
                schedulePreviewDismissal()
                return
            }
            guard hovered, preferences.previewEnabled, dragID == nil,
                  applications.running.contains(where: { $0.path == path }) else { return }
            previewTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled else { return }
                if !inFolder { expandedID = nil }
                previewPath = path
            }
        }
    }

    /// Click modifiers follow the system Dock: ⌘ reveals in Finder, ⌥ hides others (or the app itself).
    private func activate(path: String) {
        feature.fan.dismiss()
        previewTask?.cancel()
        previewPath = nil
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { applications.revealInFinder(path: path) }
        else if flags.contains(.option) { applications.openHidingOthers(path: path) }
        else { applications.open(path: path) }
    }

    /// Fan (or automatic with few files, Dock at the bottom) opens the transparent fan window;
    /// every other view opens the stack panel. A second click closes either.
    private func openStack(_ element: DockElement, sort: DockStackSort, style: DockStackStyle) {
        if feature.fan.presentedID == element.id { feature.fan.dismiss(); return }
        if expandedID == element.id { expandedID = nil; return }
        guard style == .fan || style == .automatic, preferences.position == .bottom,
              let path = element.directoryPath else { toggleExpansion(element.id); return }
        previewTask?.cancel(); previewPath = nil; expandedID = nil
        feature.fan.dismiss()
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        Task { @MainActor in
            let files = (try? await Task.detached(priority: .userInitiated) {
                try DockFileStackProvider.read(directory: directory, sort: sort)
            }.value) ?? []
            guard !files.isEmpty, style == .fan || files.count <= DockFanLayout.maxRows,
                  let anchor = feature.anchors.screenRect(element.id),
                  let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) else {
                toggleExpansion(element.id)
                return
            }
            feature.fan.present(element: element, files: files, provider: feature.stacks, anchor: anchor,
                                dockTop: feature.dockFrame?.maxY ?? anchor.maxY, screen: screen.visibleFrame,
                                interactionChanged: interaction("fan"))
        }
    }

    private func previewBinding(_ path: String?) -> Binding<Bool> {
        Binding(get: { path != nil && previewPath == path },
                set: { if !$0, previewPath == path { previewPath = nil } })
    }

    private func windowPreview(path: String, title: String) -> some View {
        DockPreviewSurface(service: feature.previews, applicationPath: path, title: title,
                           interactionChanged: interaction("preview:\(path)"), hoverChanged: { inside in
            previewDismissTask?.cancel()
            if !inside { schedulePreviewDismissal() }
        })
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedID == id }, set: { if !$0 { expandedID = nil } })
    }
    private func toggleExpansion(_ id: String) {
        feature.fan.dismiss()
        previewTask?.cancel(); previewPath = nil
        expandedID = expandedID == id ? nil : id
    }
    private func closeSurfaces() {
        expandedID = nil; previewPath = nil
        previewTask?.cancel(); previewDismissTask?.cancel(); dwell?.cancel(); feature.previews.cancel(); feature.stacks.cancel()
        dragID = nil; dropTarget = nil; groupTarget = nil; liveOrder = nil; insertion = nil
        interactionIDs.removeAll()
        interactionChanged(false)
    }

    private func schedulePreviewDismissal() {
        previewDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            previewPath = nil
        }
    }

    private func interaction(_ id: String) -> (Bool) -> Void { { setInteraction(id, active: $0) } }
    private func setInteraction(_ id: String, active: Bool) {
        if active { interactionIDs.insert(id) } else { interactionIDs.remove(id) }
        interactionChanged(!interactionIDs.isEmpty)
    }

    private func folder(_ original: DockElement) -> some View {
        DockFolderSurface(preferences: preferences, element: original, isDropTargeted: folderDropTarget == original.id,
                          interactionChanged: interaction("folder")) { child in
                        VStack(spacing: 5) {
                            appIcon(path: child.applicationPath ?? "", title: child.title, id: child.id, inFolder: true).frame(width: 64, height: 57)
                            Text(child.title).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                        }.frame(width: 72, height: 83)
                            .modifier(DockPopoverAnchor(isPresented: previewBinding(child.applicationPath)) {
                                if let path = child.applicationPath { windowPreview(path: path, title: child.title) }
                            })
                            .onDrag { beginDrag(child.id) }
                            .onDrop(of: [.utf8PlainText, .fileURL], delegate: DockElementDropDelegate(
                                item: child, length: 72, vertical: false, preferences: preferences, applications: applications,
                                dragID: $dragID, dropTarget: $dropTarget, groupTarget: $groupTarget,
                                liveOrder: .constant(nil), insertion: .constant(nil), leadingInset: 0,
                                commitLiveOrder: { _ in },
                                dwell: $dwell, expand: {}, interactionChanged: interaction("drag"),
                                receiveFiles: feature.receiveFiles, insideFolder: true))
                            .contextMenu {
                                Button("Вернуть в Dock") { preferences.moveOutOfFolder(child.id) }
                                Button("Убрать") { preferences.remove(id: child.id) }
                            }
        }
        // The whole open folder, not only its icons, takes applications dropped into it.
        .onDrop(of: [.utf8PlainText, .fileURL], delegate: DockFolderDropDelegate(
            folderID: original.id, preferences: preferences, dragID: $dragID, targeted: $folderDropTarget,
            liveOrder: $liveOrder, insertion: $insertion, groupTarget: $groupTarget, dwell: $dwell,
            interactionChanged: interaction("drag")))
    }

    /// System Dock application menu: Options, window commands, and Quit (⌥ — Force Quit).
    @ViewBuilder private func appMenu(path: String, pinnedID: String?) -> some View {
        let app = applications.running.first { $0.path == path }
        Menu("Параметры") {
            Toggle("Оставить в Dock", isOn: Binding(get: { pinnedID != nil }, set: { keep in
                if keep { _ = preferences.addApplication(URL(fileURLWithPath: path)) }
                else if let pinnedID { preferences.remove(id: pinnedID) }
            }))
            Toggle("Открывать при входе", isOn: Binding(get: { loginItems.contains(path) }, set: { _ in
                loginItems.toggle(path: path)
            }))
            Button("Показать в Finder") { applications.revealInFinder(path: path) }
            if let pinnedID, preferences.items.contains(where: { $0.id == pinnedID }) {
                Menu("Переместить в папку") {
                    ForEach(preferences.items.filter { $0.kind == .folder }) { folder in
                        Button(folder.title) { _ = preferences.moveIntoFolder(pinnedID, folderID: folder.id) }
                    }
                    Button("Новая папка") {
                        let id = preferences.addFolder(name: "Новая папка")
                        _ = preferences.moveIntoFolder(pinnedID, folderID: id)
                    }
                }
            }
        }
        Divider()
        if let app {
            Button("Показать все окна") {
                expandedID = nil
                previewTask?.cancel()
                previewPath = path
            }
            Button(app.isHidden ? "Показать" : "Скрыть") { applications.setHidden(!app.isHidden, path: path) }
            Divider()
            quitItems(path)
        } else {
            Button("Открыть") { applications.open(path: path) }
        }
    }

    @ViewBuilder private func quitItems(_ path: String) -> some View {
        if #available(macOS 15.0, *) {
            Button("Завершить") { applications.terminate(path: path) }
                .modifierKeyAlternate(.option) {
                    Button("Завершить принудительно") { applications.forceTerminate(path: path) }
                }
        } else {
            Button("Завершить") { applications.terminate(path: path) }
            Button("Завершить принудительно") { applications.forceTerminate(path: path) }
        }
    }

    @ViewBuilder private func stackMenu(sort: Binding<DockStackSort>, style: Binding<DockStackStyle>) -> some View {
        Menu("Сортировка") {
            ForEach(DockStackSort.allCases) { value in
                Toggle(value.title, isOn: Binding(get: { sort.wrappedValue == value }, set: { _ in sort.wrappedValue = value }))
            }
        }
        Menu("Вид") {
            ForEach(DockStackStyle.allCases) { value in
                Toggle(value.title, isOn: Binding(get: { style.wrappedValue == value }, set: { _ in style.wrappedValue = value }))
            }
        }
        Divider()
    }

    private func stackBinding<Value: RawRepresentable>(_ key: String, item: DockElement, fallback: Value) -> Binding<Value>
        where Value.RawValue == String {
        Binding(get: {
            let options = preferences.items.first { $0.id == item.id }?.options ?? item.options
            return Value(rawValue: options[key] ?? "") ?? fallback
        }, set: { preferences.setOption(key, value: $0.rawValue, for: item.id) })
    }

    @ViewBuilder private func itemMenu(_ item: DockElement) -> some View {
        if item.kind == .app, let path = item.applicationPath {
            appMenu(path: path, pinnedID: item.id)
        } else {
            if item.kind == .stack, let path = item.directoryPath {
                stackMenu(sort: stackBinding("sort", item: item, fallback: DockStackSort.modified),
                          style: stackBinding("style", item: item, fallback: DockStackStyle.automatic))
                Button("Открыть в Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            if item.integrationID == "music" { musicMenu }
            if item.kind == .integration, !vertical,
               let entry = DockIntegrationRegistry.integration(item.integrationID), entry.supportedSpans.count > 1 {
                Menu("Ширина") {
                    ForEach(entry.supportedSpans, id: \.self) { span in
                        Button("\(span) \(span == 1 ? "ячейка" : "ячейки")") { preferences.setSpan(span, for: item.id) }
                    }
                }
            }
            Button("Убрать из Dock") { preferences.remove(id: item.id) }
        }
    }

    /// DockView does not observe playback, so the items carry no state that could go stale.
    @ViewBuilder private var musicMenu: some View {
        Button("Воспроизвести / пауза", action: model.nowPlayingTogglePlayPause)
        Button("Следующий трек", action: model.nowPlayingNextTrack)
        Button("Предыдущий трек", action: model.nowPlayingPreviousTrack)
        Button("Подробнее…") { NotificationCenter.default.post(name: DockMusicWidget.showDetails, object: nil) }
        Button("Обновить", action: model.refreshNowPlaying)
        Divider()
    }

    /// Spring-loading, like the system Dock: holding a drag over an application brings it
    /// forward, over a stack opens its folder in Finder, so the drop can land there.
    private func spring(_ item: DockElement) {
        if item.kind == .app, let path = item.applicationPath { applications.springOpen(path: path) }
        else if item.kind == .stack { openInFinder(item) }
    }

    private func openInFinder(_ element: DockElement) {
        guard let path = element.directoryPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func springTargetChanged(_ key: String, targeted: Bool, action: @escaping @MainActor () -> Void) {
        if targeted {
            guard springKey != key, let delay = DockSpringLoading.delay else { return }
            springTask?.cancel()
            springKey = key
            springTask = Task { @MainActor in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, springKey == key else { return }
                springKey = nil; springTask = nil
                action()
            }
        } else if springKey == key {
            springTask?.cancel(); springTask = nil; springKey = nil
        }
    }

    private func openFiles(_ providers: [NSItemProvider], path: String) -> Bool {
        DockFileDrop.load(providers) { urls in applications.openFiles(urls, with: path) }
    }
}

struct DockApplicationIcon: View {
    @ObservedObject var applications: DockApplicationStore
    let path: String
    let title: String
    let magnification: Double
    var showsLabel = false
    var badge: String? = nil
    var isLaunching = false
    var dimsHidden = true
    var position: DockPosition = .bottom
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var running: DockRunningApplication? { applications.running.first { $0.path == path } }
    private var anchor: UnitPoint {
        switch position {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: applications.icon(for: path)).resizable().interpolation(.high).scaledToFit()
                .frame(width: DockLayout.iconSize, height: DockLayout.iconSize)
                .opacity(dimsHidden && running?.isHidden == true ? 0.45 : 1)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1).padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
                            .offset(x: 6, y: -5)
                            .accessibilityLabel("Уведомления: \(badge)")
                    }
                }
                .scaleEffect(hovered ? 1 + magnification * 0.12 : 1, anchor: anchor)
                .modifier(DockLaunchBounce(active: isLaunching && !reduceMotion, position: position))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Capsule().fill(running?.isActive == true ? .white : .white.opacity(0.45))
                .frame(width: running?.isActive == true ? 10 : 4, height: 3)
                .opacity(running == nil ? (isLaunching ? 0.6 : 0) : 1)
            if showsLabel {
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .truncationMode(.tail).foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity).accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .dockTapTarget(badge.map { "\(title), уведомления: \($0)" } ?? title, action: action).help(title)
            .background(.white.opacity(running?.isActive == true ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 12))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72), value: hovered)
    }
}

private func dockBounceOffset(_ phase: Double, position: DockPosition) -> CGSize {
    switch position {
    case .bottom: CGSize(width: 0, height: -14 * phase)
    case .left: CGSize(width: 14 * phase, height: 0)
    case .right: CGSize(width: -14 * phase, height: 0)
    }
}

/// Repeats until the launched application appears, away from the Dock edge.
private struct DockLaunchBounce: ViewModifier {
    let active: Bool
    let position: DockPosition

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([0.0, 1.0]) { view, phase in
                view.offset(dockBounceOffset(phase, position: position))
            } animation: { phase in phase == 1 ? .easeOut(duration: 0.28) : .easeIn(duration: 0.28) }
        } else {
            content
        }
    }
}

/// One bounce per trigger change, e.g. a finished download.
private struct DockBounceOnce: ViewModifier {
    let trigger: Int
    let position: DockPosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.phaseAnimator([0.0, 1.0], trigger: reduceMotion ? 0 : trigger) { view, phase in
            view.offset(dockBounceOffset(phase, position: position))
        } animation: { phase in phase == 1 ? .easeOut(duration: 0.25) : .easeIn(duration: 0.25) }
    }
}

/// Downloads and Trash use the application icon metrics without a running indicator.
private struct DockSystemIcon: View {
    let image: NSImage
    let title: String
    let showsLabel: Bool
    var progress: Double? = nil

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: DockLayout.iconSize, height: DockLayout.iconSize)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).progressViewStyle(.linear).tint(.white)
                            .frame(width: DockLayout.iconSize - 6).controlSize(.mini)
                            .padding(3).background(.black.opacity(0.45), in: Capsule())
                            .accessibilityLabel("Загрузка: \(Int(progress * 100))%")
                    }
                }
            Capsule().fill(.clear).frame(width: 4, height: 3)
            if showsLabel {
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    .foregroundStyle(.white.opacity(0.8)).accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
    }
}

/// Attach only after the cell's logical frame, scale and physical frame.
/// Otherwise SwiftUI resolves the arrow from the pre-transform inner icon.
struct DockPopoverAnchor<Popup: View>: ViewModifier {
    @Binding var isPresented: Bool
    var arrowEdge: Edge = .top
    @ViewBuilder var popup: () -> Popup
    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds),
                        arrowEdge: arrowEdge, content: popup)
    }
}

private struct DockFolderIcon: View {
    let element: DockElement
    @ObservedObject var applications: DockApplicationStore
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(Array(element.children.prefix(9))) { item in
                Image(nsImage: applications.icon(for: item.applicationPath ?? "")).resizable().scaledToFit().frame(width: 10, height: 10)
            }
        }.padding(5).frame(width: DockLayout.iconSize, height: DockLayout.iconSize, alignment: .topLeading)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.14), lineWidth: 0.7) }
    }
}

private final class DockDragProvider: NSItemProvider {
    init(id: String) {
        super.init()
        registerObject(id as NSString, visibility: .ownProcess)
    }
}

/// Trash takes a move, like the system Dock: a copy proposal is refused by drag sources
/// that only offer move or generic, such as files dragged out of the stack fan.
/// The system spring-loading preference (Accessibility › Pointer Control and Finder); nil when off.
enum DockSpringLoading {
    static var delay: Duration? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return nil }
        let seconds = (defaults.object(forKey: "com.apple.springing.delay") as? NSNumber)?.doubleValue ?? 0.5
        return .milliseconds(Int(min(2, max(0.1, seconds)) * 1_000))
    }
}

private struct DockTrashDropDelegate: DropDelegate {
    @Binding var targeted: Bool
    let drop: @MainActor ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText, .fileURL]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return drop(info.itemProviders(for: [.utf8PlainText, .fileURL]))
    }
}

@MainActor
private enum DockFileDrop {
    @discardableResult static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let candidates = Array(providers.lazy.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }.prefix(128))
        guard !candidates.isEmpty else { return false }
        Task { @MainActor in
            // Start requests together: a malformed provider cannot multiply the
            // two-second deadline by the number of files in the drag.
            let requests = candidates.map { provider in
                Task { @MainActor in await loadURL(from: provider) }
            }
            var urls: [URL] = []
            await withTaskCancellationHandler {
                for request in requests {
                    if let url = await request.value { urls.append(url) }
                }
            } onCancel: {
                for request in requests { request.cancel() }
            }
            if !Task.isCancelled, !urls.isEmpty { completion(urls) }
        }
        return true
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        let gate = DockFileDropLoadGate()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                guard gate.install(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                    gate.finish(nil)
                }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap {
                        URL(dataRepresentation: $0, relativeTo: nil)
                    }
                    gate.finish(url?.isFileURL == true ? url : nil)
                }
            }
        } onCancel: {
            gate.finish(nil)
        }
    }
}

/// Foundation may call back late, twice, or never. Only the first completion,
/// cancellation, or timeout may resume the continuation; all state is locked.
private final class DockFileDropLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var finished = false
    private var result: URL?

    func install(_ continuation: CheckedContinuation<URL?, Never>) -> Bool {
        lock.lock()
        if finished {
            let result = result
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: URL?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.result = result
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Drops on the free area of an open folder: Dock items, running applications and
/// applications from Finder are filed into it.
private struct DockFolderDropDelegate: DropDelegate {
    let folderID: String
    let preferences: DockPreferences
    @Binding var dragID: String?
    @Binding var targeted: String?
    @Binding var liveOrder: [String]?
    @Binding var insertion: DockInsertion?
    @Binding var groupTarget: String?
    @Binding var dwell: Task<Void, Never>?
    let interactionChanged: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.utf8PlainText, .fileURL]) }
    func dropEntered(info: DropInfo) { targeted = folderID }
    func dropExited(info: DropInfo) { if targeted == folderID { targeted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragID == nil ? .copy : .move) }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dwell?.cancel(); dwell = nil; groupTarget = nil; targeted = nil; dragID = nil
            liveOrder = nil; insertion = nil
            interactionChanged(false)
        }
        if let id = dragID { return file(id) }
        let fileProviders = info.itemProviders(for: [.fileURL])
        if fileProviders.isEmpty {
            guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String else { return }
                Task { @MainActor in _ = file(id) }
            }
            return true
        }
        return DockFileDrop.load(fileProviders) { urls in
            for url in urls where url.pathExtension.lowercased() == "app" {
                _ = file("running:" + url.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
    }

    @MainActor
    private func file(_ original: String) -> Bool {
        var id = original
        if id.hasPrefix("running:") {
            let path = String(id.dropFirst("running:".count))
            _ = preferences.addApplication(URL(fileURLWithPath: path))
            guard let pinned = preferences.flattenedApps.first(where: { $0.applicationPath == path }) else { return false }
            id = pinned.id
        }
        if preferences.items.first(where: { $0.id == folderID })?.children.contains(where: { $0.id == id }) == true {
            return true
        }
        return preferences.moveIntoFolder(id, folderID: folderID)
    }
}

private struct DockElementDropDelegate: DropDelegate {
    let item: DockElement
    /// Cell length along the Dock axis without an open gap; the outer fifths insert, the middle groups.
    let length: CGFloat
    let vertical: Bool
    let preferences: DockPreferences
    let applications: DockApplicationStore
    @Binding var dragID: String?
    @Binding var dropTarget: String?
    @Binding var groupTarget: String?
    @Binding var liveOrder: [String]?
    @Binding var insertion: DockInsertion?
    /// Width of a gap opened before the cell; pointer offsets are measured from the cell itself.
    let leadingInset: CGFloat
    let commitLiveOrder: (String) -> Void
    @Binding var dwell: Task<Void, Never>?
    let expand: () -> Void
    let interactionChanged: (Bool) -> Void
    let receiveFiles: ([URL], String) -> Void
    var spring: () -> Void = {}
    var insideFolder = false

    private func offset(_ info: DropInfo) -> CGFloat {
        (vertical ? info.location.y : info.location.x) - leadingInset
    }
    /// The middle of the cell acts on it: groups, opens files with the app, or files them into a stack.
    private var actsOnMiddle: Bool {
        if item.kind == .folder { return true }
        if dragID != nil { return item.kind == .app && !insideFolder }
        return item.kind == .app || item.kind == .stack
    }
    private var reordersLive: Bool { !insideFolder && liveOrder != nil && dragID != nil }

    func dropEntered(info: DropInfo) {
        dropTarget = item.id
        _ = dropUpdated(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = DropProposal(operation: dragID == nil ? .copy : .move)
        guard dragID != item.id else {
            cancelDwell()
            return proposal
        }
        let offset = offset(info)
        if reordersLive, let id = dragID, let order = liveOrder {
            if let moved = DockLiveReorder.reordered(order, dragged: id, target: item.id,
                                                     offset: offset, length: length) {
                cancelDwell()
                liveOrder = moved
            } else if actsOnMiddle, !DockLiveReorder.insertsAtEdge(offset: offset, length: length) {
                startDwell()
            } else { cancelDwell() }
            return proposal
        }
        if insideFolder {
            if actsOnMiddle, !DockLiveReorder.insertsAtEdge(offset: offset, length: length) { startDwell() } else { cancelDwell() }
            return proposal
        }
        if !actsOnMiddle || DockLiveReorder.insertsAtEdge(offset: offset, length: length) {
            cancelDwell()
            let next = DockInsertion(id: item.id, after: offset > length / 2)
            if insertion != next { insertion = next }
        } else {
            if insertion?.id == item.id { insertion = nil }
            startDwell()
        }
        return proposal
    }

    func dropExited(info: DropInfo) {
        cancelDwell()
        if dropTarget == item.id { dropTarget = nil }
        // Another cell takes the gap on entering; leaving the strip closes it.
        guard insertion?.id == item.id else { return }
        let gap = insertion
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            if dropTarget == nil, insertion == gap { insertion = nil }
        }
    }

    private func startDwell() {
        guard dwell == nil, groupTarget == nil else { return }
        dwell = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            groupTarget = item.id
            if item.kind == .folder { expand(); return }
            // Files held over an application or a stack spring it open; Dock items group instead.
            guard dragID == nil, !insideFolder, item.kind == .app || item.kind == .stack,
                  let delay = DockSpringLoading.delay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, groupTarget == item.id else { return }
            spring()
        }
    }
    private func cancelDwell() {
        dwell?.cancel(); dwell = nil
        if groupTarget == item.id { groupTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let offset = offset(info)
        let edge = !actsOnMiddle || DockLiveReorder.insertsAtEdge(offset: offset, length: length)
        let after = insertion?.id == item.id ? insertion?.after ?? false : offset > length * 0.5
        // A folder's middle takes the item at once, like a stack in the system Dock.
        let grouping = groupTarget == item.id || (item.kind == .folder && !edge)
        defer {
            dwell?.cancel(); dwell = nil; dropTarget = nil; groupTarget = nil; dragID = nil
            liveOrder = nil; insertion = nil
            interactionChanged(false)
        }
        if let id = dragID {
            if reordersLive {
                if grouping, id != item.id { return moveDragged(id, grouping: true, after: after) }
                commitLiveOrder(id)
                return true
            }
            return id == item.id || moveDragged(id, grouping: grouping, after: after)
        }
        let fileProviders = info.itemProviders(for: [.fileURL])
        if fileProviders.isEmpty {
            // Fallback: the drag state was lost, but our own item carries its identifier.
            guard let provider = info.itemProviders(for: [.utf8PlainText]).first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let id = object as? String else { return }
                Task { @MainActor in
                    guard id != item.id, id.hasPrefix("running:") || preferences.items.contains(where: {
                        $0.id == id || $0.children.contains { $0.id == id }
                    }) else { return }
                    _ = moveDragged(id, grouping: false, after: after)
                }
            }
            return true
        }
        return DockFileDrop.load(fileProviders) { urls in
            if !edge, item.kind == .app, let path = item.applicationPath {
                applications.openFiles(urls, with: path)
            } else if !edge, item.kind == .stack, let directory = item.directoryPath {
                // Like a Finder folder: move on the same volume, copy across volumes or with ⌥.
                receiveFiles(urls, directory)
            } else {
                // Applications and folders from Finder are inserted where they were dropped.
                for url in urls {
                    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                    if url.pathExtension.lowercased() == "app" {
                        guard preferences.addApplication(url),
                              let added = preferences.flattenedApps.first(where: { $0.applicationPath == path }) else { continue }
                        if item.kind == .folder, !edge { _ = preferences.moveIntoFolder(added.id, folderID: item.id) }
                        else if insideFolder { _ = joinFolder(added.id, after: after) }
                        else { place(added.id, after: after) }
                    } else if !insideFolder, preferences.addStack(url) {
                        place("stack:\(path)", after: after)
                    }
                }
            }
        }
    }

    @MainActor
    private func moveDragged(_ original: String, grouping: Bool, after: Bool) -> Bool {
        var id = original
        if id.hasPrefix("running:") {
            let path = String(id.dropFirst("running:".count))
            _ = preferences.addApplication(URL(fileURLWithPath: path))
            guard let pinned = preferences.flattenedApps.first(where: { $0.applicationPath == path }) else { return false }
            id = pinned.id
        }
        guard id != item.id else { return true }
        if grouping, item.kind == .folder { return preferences.moveIntoFolder(id, folderID: item.id) }
        if grouping, item.kind == .app, !insideFolder { return preferences.group(id, with: item.id) }
        if insideFolder { return joinFolder(id, after: after) }
        if !insideFolder, preferences.items.flatMap(\.children).contains(where: { $0.id == id }) {
            preferences.moveOutOfFolder(id, before: item.id)
        }
        place(id, after: after)
        return true
    }

    /// Inside an open folder: brings an item from elsewhere into this folder, then places it.
    @MainActor
    private func joinFolder(_ id: String, after: Bool) -> Bool {
        guard let folder = preferences.items.first(where: { $0.children.contains { $0.id == item.id } }) else { return false }
        if !folder.children.contains(where: { $0.id == id }),
           !preferences.moveIntoFolder(id, folderID: folder.id) { return false }
        place(id, after: after)
        return true
    }

    /// Inserts before the target, or after it when dropped on its trailing half.
    @MainActor
    private func place(_ id: String, after: Bool) {
        guard id != item.id else { return }
        let siblings = insideFolder
            ? preferences.items.first { $0.children.contains { $0.id == item.id } }?.children.map(\.id) ?? []
            : preferences.items.map(\.id)
        guard let index = siblings.firstIndex(of: item.id) else { return }
        guard after else { preferences.move(id: id, before: item.id); return }
        let following = siblings.dropFirst(index + 1).first { $0 != id }
        if let following { preferences.move(id: id, before: following) }
        else if !insideFolder { preferences.moveToEnd(id: id) }
    }
}
