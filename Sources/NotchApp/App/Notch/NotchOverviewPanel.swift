import SwiftUI

/// Lightweight navigation only: opening the overview does not mount every feature panel.
struct NotchOverviewPanel: View {
    @ObservedObject var model: NotchViewModel
    let onOpenSettings: () -> Void
    @State private var query = ""

    private func matches(_ text: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || text.localizedStandardContains(value)
    }

    private var matchingPanels: [PanelID] {
        model.visiblePanels.filter { matches($0.title + " " + $0.rawValue) }
    }

    private var showsFiles: Bool {
        model.modules.isEnabled(.fileShelf) && matches("Файлы полка files")
    }

    private var showsSearch: Bool { matches("Поиск задачи сессии события search") }
    private var showsCaptures: Bool {
        model.modules.isEnabled(.recentCaptures) && matches("Недавние снимки скриншоты изображения screenshots captures")
    }
    private var showsScratchpad: Bool {
        model.modules.isEnabled(.scratchpad) && matches("Черновик заметки notes scratchpad")
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(NotchPalette.secondary)
                TextField("Найти раздел", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Найти раздел")
                    .onSubmit { openFirstResult() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Очистить поиск разделов")
                }
            }
            .font(.system(size: 12))
            .padding(10)
            .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 10))

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(matchingPanels) { panel in
                        tile(panel.title, icon: panel.iconName) { model.selectPanel(panel) }
                    }
                    if showsFiles {
                        tile("Файлы", icon: "tray") { model.openUtility(.files) }
                    }
                    if showsScratchpad {
                        tile("Черновик", icon: "square.and.pencil") { model.openUtility(.scratchpad) }
                    }
                    if showsCaptures {
                        tile("Недавние снимки", icon: "photo.on.rectangle") { model.openUtility(.recentCaptures) }
                    }
                    if showsSearch {
                        tile("Поиск по данным", icon: "magnifyingglass") { model.openUtility(.search) }
                    }
                }
                if matchingPanels.isEmpty && !showsFiles && !showsSearch && !showsScratchpad && !showsCaptures {
                    Text("Раздел не найден")
                        .font(.system(size: 12))
                        .foregroundStyle(NotchPalette.secondary)
                        .padding(.top, 20)
                }
            }

            Button(action: onOpenSettings) {
                Label("Настроить модули", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(NotchButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
    }

    private func tile(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NotchPalette.accent)
                    .frame(width: 24)
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NotchPalette.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(NotchPalette.raised, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(NotchButtonStyle())
        .accessibilityLabel("Открыть раздел \(title)")
    }

    private func openFirstResult() {
        if let panel = matchingPanels.first { model.selectPanel(panel) }
        else if showsFiles { model.openUtility(.files) }
        else if showsScratchpad { model.openUtility(.scratchpad) }
        else if showsCaptures { model.openUtility(.recentCaptures) }
        else if showsSearch { model.openUtility(.search) }
    }
}
