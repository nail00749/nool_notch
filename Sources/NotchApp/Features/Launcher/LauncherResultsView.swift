import AppKit
import SwiftUI

struct LauncherApplicationLayoutPicker: View {
    @ObservedObject var settings: LauncherSettings
    let focusInput: () -> Void

    var body: some View {
        HStack {
            Text("Вид приложений")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchPalette.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(LauncherApplicationLayout.allCases) { layout in
                    Button {
                        settings.applicationLayout = layout
                        focusInput()
                    } label: {
                        Label(layout.title, systemImage: layout.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(settings.applicationLayout == layout ? LauncherSelectionStyle.background : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(settings.applicationLayout == layout ? LauncherSelectionStyle.text : NotchPalette.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Показывать приложения: \(layout.title.lowercased())")
                    .accessibilityAddTraits(settings.applicationLayout == layout ? [.isSelected] : [])
                }
            }
            .padding(3)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Вид приложений")
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct LauncherResultsView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var settings: LauncherSettings
    let activate: (LauncherResult, Bool) -> Void
    let performAction: (LauncherResultAction, LauncherResult) -> Void

    private var rows: [[LauncherResult]] {
        model.usesApplicationGrid ? LauncherResultLayout.rows(model.results) : model.results.map { [$0] }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: model.usesApplicationGrid ? 8 : 3) {
                    ForEach(rows, id: \.first!.id) { row in
                        if model.usesApplicationGrid, let first = row.first, case .application = first.payload {
                            HStack(alignment: .top, spacing: 8) {
                                ForEach(row) { result in
                                    interactive(result) {
                                        LauncherApplicationTile(result: result, selected: model.selectedID == result.id, icons: model.icons)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                ForEach(0..<(LauncherResultLayout.columns - row.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                                        .accessibilityHidden(true)
                                }
                            }
                        } else if let result = row.first {
                            interactive(result) {
                                LauncherResultRow(result: result, selected: model.selectedID == result.id,
                                                  icons: model.icons, clipboardData: clipboardData(for: result))
                            }
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
            .onChange(of: settings.applicationLayout) { _, _ in
                // Wait for the new layout before locating the existing selection.
                Task { @MainActor in
                    await Task.yield()
                    if let id = model.selectedID { proxy.scrollTo(id, anchor: nil) }
                }
            }
        }
    }

    private func interactive<Content: View>(_ result: LauncherResult, @ViewBuilder content: () -> Content) -> some View {
        Button {
            model.selectResult(result.id)
            activate(result, false)
        } label: {
            content().contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(model.selectedID == result.id ? [.isSelected] : [])
            .contextMenu {
                ForEach(model.resultActions(for: result)) { action in
                    Button(action.title) { performAction(action, result) }
                }
            }
            .id(result.id)
    }

    private func clipboardData(for result: LauncherResult) -> Data? {
        guard case .clipboard(let id) = result.payload else { return nil }
        return model.clipboard.items.first { $0.id == id }?.imageData
    }
}

private struct LauncherApplicationTile: View {
    let result: LauncherResult
    let selected: Bool
    let icons: LauncherIcons
    @State private var icon: NSImage?
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().padding(8)
                        .foregroundStyle(NotchPalette.secondary)
                }
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)
            Text(result.title)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 32, alignment: .top)
        }
        .foregroundStyle(selected ? LauncherSelectionStyle.text : NotchPalette.text)
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(selected ? LauncherSelectionStyle.background :
                        (hovered ? Color(nsColor: .controlBackgroundColor).opacity(0.7) : .clear),
                    in: RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .help("\(result.title)\n\(result.subtitle)")
        .task(id: result.id) { icon = await icons.image(for: result, clipboardData: nil) }
    }
}
